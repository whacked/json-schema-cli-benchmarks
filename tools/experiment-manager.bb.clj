#!/usr/bin/env bb
;; Experiment manager - scaffolding, validation, status
;; Usage: ./tools/experiment-manager.bb <command> <draft>

(require '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[cheshire.core :as json]
         '[clj-yaml.core :as yaml]
         '[clojure.string :as str])

;; Forward declarations
(declare cmd-status)

;; -----------------------------------------------------------------------------
;; Config
;; -----------------------------------------------------------------------------

(def repo-root (-> *file* fs/parent fs/parent))
(def experiments-dir (fs/path repo-root "experiments"))
(def schemas-dir (fs/path repo-root "schemas"))
(def dirschema-dir (fs/path repo-root "dirschema"))

;; -----------------------------------------------------------------------------
;; Shell helpers (minimal - only for tools bb can't replace)
;; -----------------------------------------------------------------------------

(defn sh
  "Run command, return {:exit :out :err}"
  ^java.util.Map [& args]
  (-> (p/process args {:out :string :err :string})
      deref
      (select-keys [:exit :out :err])))

(defn sh-ok?
  "Run command, return true if exit code is 0"
  ^Boolean [& args]
  (-> (apply sh args) :exit zero?))

(defn sh-json
  "Run command, parse stdout as JSON"
  [& args]
  (-> (apply sh args) :out (json/parse-string true)))

(defn sh-stdin
  "Run command with stdin data"
  ^java.util.Map [^String stdin-str & args]
  (-> (p/process args {:in stdin-str :out :string :err :string})
      deref
      (select-keys [:exit :out :err])))

;; -----------------------------------------------------------------------------
;; Manifest helpers (native bb - YAML/JSON)
;; -----------------------------------------------------------------------------

(defn manifest-path
  "Returns path to manifest (yaml preferred) or nil"
  ^java.nio.file.Path [^String draft]
  (let [yaml-path (fs/path experiments-dir draft "manifest.yaml")
        json-path (fs/path experiments-dir draft "manifest.json")]
    (cond
      (fs/exists? yaml-path) yaml-path
      (fs/exists? json-path) json-path)))

(defn load-manifest
  "Load manifest as Clojure data, or nil if not found"
  ^java.util.Map [^String draft]
  (when-let [path (manifest-path draft)]
    (let [content (slurp (str path))]
      (if (str/ends-with? (str path) ".yaml")
        (yaml/parse-string content :keywords true)
        (json/parse-string content true)))))

(defn save-manifest-yaml
  "Save data as YAML manifest, returns path"
  ^java.nio.file.Path [^String draft ^java.util.Map data]
  (let [path (fs/path experiments-dir draft "manifest.yaml")]
    (spit (str path) (yaml/generate-string data :dumper-options {:flow-style :block}))
    path))

;; -----------------------------------------------------------------------------
;; External tool calls (one-liners, no wrappers needed)
;; -----------------------------------------------------------------------------

;; jsonnet: (sh-json "jsonnet" "--ext-str" "draft=x" "template.jsonnet")
;; dirschema: (sh-stdin spec-json "dirschema" "hydrate" "--root" dir "-")
;; check-jsonschema: (sh-ok? "check-jsonschema" "--schemafile" schema target)

;; -----------------------------------------------------------------------------
;; State gathering (pure bb, inspectable)
;; -----------------------------------------------------------------------------

(defn run-dirschema-validate
  "Run dirschema validate with JSON output. Returns {:valid bool :errors [...]} or nil."
  ^java.util.Map [^String draft ^java.util.Map manifest]
  (when manifest
    (try
      (let [spec (sh-json "jsonnet"
                          "--ext-code" (str "manifest=" (json/generate-string manifest))
                          (str (fs/path dirschema-dir "experiment-cases.jsonnet")))
            result (sh-stdin (json/generate-string spec)
                             "dirschema" "validate" "-format" "json"
                             "--root" (str (fs/path experiments-dir draft)) "-")]
        (if (zero? (:exit result))
          {:valid true :errors []}
          ;; Parse JSON output for structured errors
          (let [parsed (json/parse-string (:out result) true)]
            {:valid false :errors (or (:errors parsed) [])})))
      (catch Exception e
        {:valid false :errors [{:message (str "dirschema error: " (.getMessage e))}]}))))

(defn gather-state
  "Collect all state needed for status display. Pure data, no side effects."
  ^java.util.Map [^String draft]
  (let [exp-dir (fs/path experiments-dir draft)
        mpath (manifest-path draft)
        manifest (load-manifest draft)
        cases (or (:cases manifest) {})
        dirschema-result (run-dirschema-validate draft manifest)
        ;; Simple check: does cases/ directory exist?
        cases-dir-exists (fs/exists? (fs/path exp-dir "cases"))]
    ;; (println "CASES EXIST" cases-dir-exists draft)
    ;; (println "===========" dirschema-result)
    {:draft draft
     :exp-dir (str exp-dir)
     :manifest-path (some-> mpath str)
     :manifest-name (some-> mpath fs/file-name str)
     :manifest manifest
     :case-count (count cases)
     :dir-exists (fs/exists? exp-dir)
     :cases-dir-exists cases-dir-exists
     :dirschema-valid (:valid dirschema-result)
     :dirschema-errors (:errors dirschema-result [])}))

(defn add-schema-validation
  "Add schema validation result (requires shell call)"
  ^java.util.Map [^java.util.Map state]
  (if-let [mpath (:manifest-path state)]
    (let [schema (str (fs/path schemas-dir "manifest.schema.json"))
          result (sh "check-jsonschema" "--schemafile" schema mpath)]
      (assoc state
             :schema-valid (zero? (:exit result))
             :schema-errors (when-not (zero? (:exit result)) (:err result))))
    state))

;; -----------------------------------------------------------------------------
;; Step definitions (single source of truth)
;; -----------------------------------------------------------------------------

(defrecord Step [^clojure.lang.Keyword id
                 ^String name
                 ^clojure.lang.IFn check])

(def steps
  "Ordered steps with predicates. Each step's check fn returns {:done bool :mark str :detail str}"
  [(->Step :new "new"
           (fn [s]
             (if (:manifest-path s)
               {:done true :detail (:manifest-name s)}
               {:done false :detail "create experiment"})))

   (->Step :schema "schema"
           (fn [s]
             (cond
               (not (:manifest-path s)) {:done false :detail "no manifest"}
               (:schema-valid s) {:done true :detail (str (:manifest-name s) " valid")}
               :else {:done false :mark "!" :detail (str (:manifest-name s) " INVALID")})))

   (->Step :edit "edit"
           (fn [s]
             (cond
               (not (:manifest-path s)) {:done false :detail "add cases to manifest"}
               (pos? (:case-count s)) {:done true :detail (str (:case-count s) " cases defined")}
               :else {:done false :detail "add cases to manifest"})))

   (->Step :hydrate "hydrate"
           (fn [s]
             (cond
               (not (pos? (:case-count s))) {:done false :detail "define cases first"}
               (:cases-dir-exists s) {:done true :detail "cases/ exists"}
               :else {:done false :detail "run hydrate command"})))

   (->Step :content "content"
           (fn [s]
             (let [errors (:dirschema-errors s [])]
               (cond
                 (not (pos? (:case-count s))) {:done false :detail "define cases first"}
                 (:dirschema-valid s) {:done true :detail "all files present"}
                 :else {:done false
                        :detail (str (count errors) " missing: "
                                     (->> errors
                                          (map :message)
                                          (str/join ", ")))}))))

   (->Step :validate "validate"
           (fn [s]
             ;; Validate is optional - mark as "?" but don't block ready state
             ;; Only show as actionable if content is complete
             (if (pos? (:case-count s))
               {:done true :mark "?" :detail "run make validate-experiment"}
               {:done false :detail "check structure"})))])

(defn next-action
  "Determine what user should do next"
  ^String [^java.util.Map state ^Step first-incomplete-step]
  (case (:id first-incomplete-step)
    :new (str "make new-experiment DRAFT=" (:draft state))
    :schema (str "fix " (:manifest-name state) " errors")
    :edit (str "edit " (:manifest-path state))
    :hydrate (str "make hydrate-experiment DRAFT=" (:draft state))
    :content "fill in missing files"
    :validate (str "make validate-experiment DRAFT=" (:draft state))
    nil))

;; -----------------------------------------------------------------------------
;; Rendering
;; -----------------------------------------------------------------------------

(defn render-status
  "Render status checklist from state"
  ^nil [^java.util.Map state]
  (println)
  (println (str "=== " (:draft state) " ==="))

  (loop [remaining steps
         first-incomplete nil]
    (if-let [step (first remaining)]
      (let [{:keys [done mark detail]} ((:check step) state)
            mark (or mark (if done "x" " "))]
        (println (format "  [%s] %-9s - %s" mark (:name step) detail))
        (recur (rest remaining)
               (or first-incomplete (when-not done step))))

      ;; After loop - show next action
      (do
        (println)
        (if first-incomplete
          (when-let [action (next-action state first-incomplete)]
            (println (str "Next: " action)))
          (println (str "Ready: make run-" (:draft state))))))))

(defn render-state-debug
  "Dump state for debugging"
  ^nil [^java.util.Map state]
  (println (json/generate-string (dissoc state :manifest) {:pretty true})))

;; -----------------------------------------------------------------------------
;; Discovery
;; -----------------------------------------------------------------------------

(defn discover-drafts
  "Find all drafts that have a manifest"
  ^clojure.lang.ISeq []
  (->> (fs/list-dir experiments-dir)
       (filter fs/directory?)
       (filter #(or (fs/exists? (fs/path % "manifest.yaml"))
                    (fs/exists? (fs/path % "manifest.json"))))
       (map #(fs/file-name %))
       (sort)))

;; -----------------------------------------------------------------------------
;; Commands
;; -----------------------------------------------------------------------------

(defn cmd-new
  ^nil [^String draft]
  (when (manifest-path draft)
    (binding [*out* *err*]
      (println (str "ERROR: manifest already exists: " (manifest-path draft))))
    (System/exit 1))

  ;; Create directory
  (fs/create-dirs (fs/path experiments-dir draft))

  ;; Generate from jsonnet template -> YAML
  (let [spec (sh-json "jsonnet" "--ext-str" (str "draft=" draft)
                      (str (fs/path dirschema-dir "manifest.template.jsonnet")))
        path (save-manifest-yaml draft spec)]
    (println (str "Created: " path)))

  (cmd-status draft))

(defn cmd-hydrate
  ^nil [^String draft]
  (let [manifest (load-manifest draft)]
    (when-not manifest
      (binding [*out* *err*] (println "ERROR: manifest not found"))
      (System/exit 1))

    ;; Generate dirschema spec from manifest via jsonnet, pipe to dirschema
    (let [spec (sh-json "jsonnet"
                        "--ext-code" (str "manifest=" (json/generate-string manifest))
                        (str (fs/path dirschema-dir "experiment-cases.jsonnet")))
          result (sh-stdin (json/generate-string spec)
                           "dirschema" "hydrate" "--root" (str (fs/path experiments-dir draft)) "-")]
      (if (zero? (:exit result))
        (println "Hydrated case directories.")
        (do (println (:err result))
            (System/exit 1)))))

  (cmd-status draft))

(defn cmd-validate
  ^nil [^String draft]
  (let [manifest (load-manifest draft)]
    (when-not manifest
      (binding [*out* *err*] (println "ERROR: manifest not found"))
      (System/exit 1))

    (let [spec (sh-json "jsonnet"
                        "--ext-code" (str "manifest=" (json/generate-string manifest))
                        (str (fs/path dirschema-dir "experiment-cases.jsonnet")))
          result (sh-stdin (json/generate-string spec)
                           "dirschema" "validate" "--root" (str (fs/path experiments-dir draft)) "-")]
      (if (zero? (:exit result))
        (println "Validation passed.")
        (do (println "Validation failed.")
            (println (:err result))
            (System/exit 1))))))

(defn cmd-status
  "Show status for one draft, or list all drafts if none given"
  ^nil
  ([]
   (let [drafts (discover-drafts)]
     (if (empty? drafts)
       (println "No experiments found. Run: new <draft>")
       (doseq [draft drafts]
         (cmd-status draft)))))
  ([^String draft]
   (-> (gather-state draft)
       (add-schema-validation)
       (render-status))))

(defn cmd-debug
  ^nil [^String draft]
  (-> (gather-state draft)
      (add-schema-validation)
      (render-state-debug)))

;; -----------------------------------------------------------------------------
;; Main
;; -----------------------------------------------------------------------------

(def script-name (fs/file-name *file*))

(defn usage
  ^nil []
  (println (str "Usage: " script-name " <command> [draft]"))
  (println)
  (println "Commands:")
  (println "  new <draft>       Create new experiment with manifest.yaml")
  (println "  hydrate <draft>   Create case directories from manifest")
  (println "  validate <draft>  Validate structure matches manifest")
  (println "  status [draft]    Show setup progress (all drafts if none given)")
  (println "  debug <draft>     Dump state as JSON (for debugging)"))

(let [[cmd draft & _] *command-line-args*]
  (cond
    ;; No args: show usage + status of all drafts
    (nil? cmd)
    (do (usage)
        (println)
        (cmd-status))

    ;; status without draft: show all
    (and (= cmd "status") (nil? draft))
    (cmd-status)

    ;; Commands that require draft
    (and (nil? draft) (#{"new" "hydrate" "validate" "debug"} cmd))
    (do (binding [*out* *err*]
          (println (str "ERROR: " cmd " requires a draft argument")))
        (System/exit 1))

    :else
    (case cmd
      "new"      (cmd-new draft)
      "hydrate"  (cmd-hydrate draft)
      "validate" (cmd-validate draft)
      "status"   (cmd-status draft)
      "debug"    (cmd-debug draft)
      (do (usage)
          (System/exit 1)))))
