;;; org-catalyst.el --- TODO description -*- lexical-binding: t -*-

;; Author: TommyX
;; Maintainer: TommyX
;; Version: 0.0.1
;; Package-Requires: (TODO)
;; Homepage: TODO
;; Keywords: TODO


;; This file is not part of GNU Emacs

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.


;;; Commentary:

;; TODO commentary

;;; Code:

;;; Dependencies

(require 'cl-lib)
(require 'calendar)
(require 'f)
(require 'ht)
(require 'json)
(require 'org)
(require 'org-id)
(require 's)

;;; LRU Library

;; NOTE:
;; Reference:
;; https://stackoverflow.com/questions/6652956/how-can-i-implement-an-expiring-lru-cache-in-elisp

(defstruct org-catalyst--lru-cache size newest oldest table)
(defstruct org-catalyst--lru-item key value next prev)

(defun org-catalyst--lru-remove-item (item lru)
  "Remove ITEM from LRU doubly linked list."
  (let ((next (org-catalyst--lru-item-next item))
        (prev (org-catalyst--lru-item-prev item)))
    (if next (setf (org-catalyst--lru-item-prev next) prev)
      (setf (org-catalyst--lru-cache-newest lru) prev))
    (if prev (setf (org-catalyst--lru-item-next prev) next)
      (setf (org-catalyst--lru-cache-oldest lru) next))))

(defun org-catalyst--lru-insert-item (item lru)
  "Insert ITEM into earliest of LRU doubly linked list."
  (let ((newest (org-catalyst--lru-cache-newest lru)))
    (setf (org-catalyst--lru-item-next item) nil (org-catalyst--lru-item-prev item) newest)
    (if newest (setf (org-catalyst--lru-item-next newest) item)
      (setf (org-catalyst--lru-cache-oldest lru) item))
    (setf (org-catalyst--lru-cache-newest lru) item)))

(defun org-catalyst--lru-create ()
  "Create a new least-recently-used cache and return it."
  (make-org-catalyst--lru-cache
   :size 0
   :newest nil
   :oldest nil
   :table (ht-create)))

(defun org-catalyst--lru-get (lru key &optional default)
  "Look up KEY in least-recently-used cache LRU and return its associated value.
If KEY is not found, return DEFAULT which defaults to nil.
The accessed entry is updated to be the earliest entry of the cache."
  (let ((item (ht-get (org-catalyst--lru-cache-table lru) key)))
    (if item
        (progn
          (org-catalyst--lru-remove-item item lru)
          (org-catalyst--lru-insert-item item lru)
          (org-catalyst--lru-item-value item))
      default)))

(defun org-catalyst--lru-remove (lru key)
  "Remove KEY from least-recently-used cache LRU."
  (let ((item (ht-get (org-catalyst--lru-cache-table lru) key)))
    (when item
      (ht-remove (org-catalyst--lru-cache-table lru)
                 (org-catalyst--lru-item-key item))
      (org-catalyst--lru-remove-item item lru)
      (decf (org-catalyst--lru-cache-size lru)))))

(defun org-catalyst--lru-set (lru key value)
  "Associate KEY with VALUE in least-recently-used cache LRU.
If KEY is already present in LRU, replace its current value with VALUE.
The accessed entry is updated to be the earliest entry of the cache."
  (let ((item (ht-get (org-catalyst--lru-cache-table lru) key)))
    (if item
        (progn
          (setf (org-catalyst--lru-item-value item) value)
          (org-catalyst--lru-remove-item item lru)
          (org-catalyst--lru-insert-item item lru))
      (let ((newitem (make-org-catalyst--lru-item :key key :value value)))
        (org-catalyst--lru-insert-item newitem lru)
        (ht-set (org-catalyst--lru-cache-table lru) key newitem)
        (incf (org-catalyst--lru-cache-size lru))))))

(defun org-catalyst--lru-evict (lru max-size)
  "Evict least recently used entries until LRU has MAX-SIZE."
  (while (> (org-catalyst--lru-cache-size lru)
            max-size)
    (org-catalyst--lru-remove lru
                              (org-catalyst--lru-item-key
                               (org-catalyst--lru-cache-oldest lru)))))

(defun org-catalyst--lru-contains (lru key)
  "Return t if LRU contain KEY."
  (ht-contains-p (org-catalyst--lru-cache-table lru) key))

;;; Constants

;; TODO make this customizable
(defconst org-catalyst--snapshot-suffix "-snapshot.json")
(defconst org-catalyst--history-suffix "-history.json")
(defconst org-catalyst--state-delta-prefix "delta_")
(defconst org-catalyst--param-prefix "param_")
(defconst org-catalyst--key-bindings
  (list (list (kbd "q") 'org-catalyst-status-quit)
        (list (kbd "r") 'org-catalyst-status-refresh)
        (list (kbd "a") 'org-catalyst-complete-item-toggle)
        (list (kbd "p") 'org-catalyst-pardon-item-toggle)
        (list (kbd "H") 'org-catalyst-status-earlier)
        (list (kbd "L") 'org-catalyst-status-later)
        (list (kbd "t") 'org-catalyst-status-goto-date)
        (list (kbd "T") 'org-catalyst-status-goto-today)))

;;; Variables

(defvar org-catalyst--state-systems (ht-create)
  "List of all installed state systems.")
(defvar org-catalyst--item-systems (ht-create)
  "List of all installed item systems.")
(defvar org-catalyst--buffered-snapshots (org-catalyst--lru-create)
  "In-memory buffer for all snapshot objects.")
(defvar org-catalyst--buffered-histories (org-catalyst--lru-create)
  "In-memory buffer for all history objects.")
(defvar org-catalyst--modified-snapshot-keys (ht-create)
  "Keys of modified snapshots.")
(defvar org-catalyst--modified-history-keys (ht-create)
  "Keys of modified histories.")
(defvar org-catalyst--auto-save-timer nil
  "Timer for `org-catalyst-auto-save-mode'.")
(defvar org-catalyst--inhibit-save nil
  "Whether to prevent auto saving temporarily.")
(defvar org-catalyst--earliest-month-day nil
  ;; NOTE: make this better.
  "Earliest month-day of all snapshots.")
(defvar org-catalyst--earliest-modified-month-day nil
  "Earliest month-day of modification.")
(defvar org-catalyst--computing-snapshot nil
  "Flag to avoid infinite recurison.")
(defvar org-catalyst--cached-config nil
  "Cached config in status buffer.")
(defvar org-catalyst--config-cache-valid nil
  "Whether cache is valid in status buffer.")
(defvar-local org-catalyst--prev-window-conf nil
  "Saved window configuration for restore.")
(defvar-local org-catalyst--status-month-day nil
  "The current month-day displayed in status window.")
(put 'org-catalyst--prev-window-conf 'permanent-local t)

;;; Customizations

(defgroup org-catalyst nil
  "Options for org-catalyst."
  :link '(url-link :tag "Github" "https://github.com/TommyX12/org-catalyst")
  :group 'org
  :prefix "org-catalyst-")

(defcustom org-catalyst-save-path
  (f-join org-directory "org-catalyst")
  "Path to org-catalyst config file."
  :group 'org-catalyst
  :type 'string)

(defcustom org-catalyst-display-buffer-function
  'org-catalyst--display-buffer-fullframe
  "The function used display a Catalyst buffer."
  :group 'org-catalyst
  :type '(radio (function-item org-catalyst--display-buffer-fullframe)
                (function :tag "Function")))

(defcustom org-catalyst-level-function
  'org-catalyst--default-level-function
  "The function used to compute amount per level."
  :group 'org-catalyst
  :type '(radio (function-item org-catalyst--default-level-function)
                (function :tag "Function")))

(defcustom org-catalyst-max-level 99
  "The maximum level."
  :group 'org-catalyst
  :type 'integer)

(defcustom org-catalyst-buffer-name "*Catalyst*"
  "Name of Catalyst status buffer."
  :group 'org-catalyst
  :type 'string)

(defcustom org-catalyst-auto-save-idle-delay 5
  "The idle delay to automatically save org-catalyst game when `org-catalyst-auto-save-mode' is on."
  :group 'org-catalyst
  :type 'float)

(defcustom org-catalyst-status-today-format "%Y-%m-%d %A"
  "The time format for the today's date in status window.

See `format-time-string'."
  :group 'org-catalyst
  :type 'string)

(defcustom org-catalyst-snapshot-cache-size 64
  "The number of snapshots to cache in memory."
  :group 'org-catalyst
  :type 'integer)

(defcustom org-catalyst-history-cache-size 64
  "The number of histories to cache in memory."
  :group 'org-catalyst
  :type 'integer)

(defcustom org-catalyst-day-start-hour 6
  "Starting hour of a day.

This is used to determine the default day to show in the status window."
  :group 'org-catalyst
  :type 'float)

;; TODO: make this more customizable
(defcustom org-catalyst-status-sections nil
  "The sections to render for status window."
  :group 'org-catalyst
  :type `(repeat
          (symbol :tag "Section name")))

;;; Faces

(defface org-catalyst-section-heading-face
  '((t :inherit org-agenda-structure))
  "Face for Catalyst section heading."
  :group 'org-catalyst)

(defface org-catalyst-state-delta-face
  '((t :inherit font-lock-constant-face))
  "Face for Catalyst state delta."
  :group 'org-catalyst)

(defface org-catalyst-section-heading-warning-face
  '((t :inherit font-lock-warning-face))
  "Face for Catalyst warning section heading."
  :group 'org-catalyst)

(defface org-catalyst-date-face
  '((t :inherit org-agenda-date))
  "Face for Catalyst heading date."
  :group 'org-catalyst)

(defface org-catalyst-today-face
  '((t :inherit org-agenda-date-today))
  "Face for Catalyst today's date."
  :group 'org-catalyst)

(defface org-catalyst-done-face
  '((t :inherit org-agenda-done))
  "Face for Catalyst text related to \"done\"."
  :group 'org-catalyst)

(defface org-catalyst-negative-done-face
  '((t :inherit font-lock-warning-face))
  "Face for Catalyst text related to \"done\" but negatively."
  :group 'org-catalyst)

(defface org-catalyst-pardon-face
  '((t :inherit org-scheduled))
  "Face for Catalyst text related to \"pardon\"."
  :group 'org-catalyst)

;;; Functions and Macros

(defun org-catalyst-setup-status-bindings (&optional evil map)
  "Bind default key bindings for the status window.

If EVIL is non-nil, bind to evil motion and normal state instead.

If MAP is non-nil, bind to that keymap."
  (let ((map (or map org-catalyst-mode-map)))
    (dolist (binding org-catalyst--key-bindings)
      (if evil
          (apply #'evil-define-key* '(motion normal) map binding)
        (apply #'define-key map binding)))))

(defun org-catalyst-setup-evil-status-bindings ()
  "Bind default key bindings for the status window using evil."
  (org-catalyst-setup-status-bindings t))

(defun org-catalyst-install-system (attribute type continuous update-func)
  "Install a system with UPDATE-FUNC for ATTRIBUTE on TYPE.
If CONTINUOUS is non-nil, the system runs consecutively through every day."
  (let ((system (ht-create)))
    (ht-set system "type" type)
    (ht-set system "continuous" continuous)
    (ht-set system "update-func" update-func)
    (cond
     ((eq type 'state)
      (ht-set org-catalyst--state-systems attribute system))
     ((eq type 'item)
      (ht-set org-catalyst--item-systems attribute system))
     (t
      (error "Invalid system type %s" (prin1-to-string type))))))

(defun org-catalyst-safe-get (table key default)
  "Get the value for KEY in TABLE.

Fallback to DEFAULT if TABLE is nil, or if KEY does not exist."
  (or (and table
           (ht-get table key default))
      default))

(defun org-catalyst-safe-update (table key default mapper)
  "Update TABLE's entry with KEY using MAPPER.

MAPPER will take one argument, which is the value before update.
It should return the value after update.

If KEY doesn't exist in TABLE or value is nil, DEFAULT will be passed to MAPPER."
  (ht-set table key
          (funcall mapper (or (ht-get table key)
                              default))))

(defun org-catalyst-install-default-systems ()
  "Install a set of default systems."

  (org-catalyst-install-system
   "total" 'state nil
   (lambda (state-attr action delta month-day params)
     (org-catalyst-safe-update
      state-attr "total" 0
      (lambda (prev)
        (+ prev
           (* (org-catalyst-safe-get action "done" 0)
              delta
              (org-catalyst-safe-get params "mul" 1)))))
     state-attr))

  (org-catalyst-install-system
   "count" 'item nil
   (lambda (item-attr action month-day params)
     (org-catalyst-safe-update
      item-attr "count" 0
      (lambda (prev)
        (+ prev
           (org-catalyst-safe-get action "done" 0))))
     item-attr))

  (org-catalyst-install-system
   "chain" 'item t
   ;; NOTE: inverse chain might be different since we assume "done"
   (lambda (item-attr action month-day params)
     (let* ((inverse (org-catalyst-safe-get params "negative" nil))
            (done (if (> (org-catalyst-safe-get action "done" 0) 0)
                      1
                    0))
            (done (if inverse
                      (- 1 done)
                    done))
            (pardon (if (> (org-catalyst-safe-get action "pardon" 0) 0)
                        1
                      0))
            (day-index
             (org-catalyst--month-day-to-days month-day))
            (last-chain-day-index
             (+ pardon
                (org-catalyst-safe-get item-attr "last-chain-day-index"
                                       (if inverse
                                           (1- day-index)
                                         1))))
            (days-since-last
             (- day-index
                last-chain-day-index))
            (chain-interval
             (org-catalyst-safe-get params "chain_interval" 1)))
       (org-catalyst-safe-update
        item-attr "chain" (if inverse
                              "inf"
                            0)
        (lambda (prev)
          (let* ((prev (if (equal prev "inf")
                           1.0e+INF
                         prev))
                 (result (+ (if (> days-since-last chain-interval)
                                0
                              prev)
                            done)))
            (if (= result 1.0e+INF)
                "inf"
              (round result)))))
       (ht-set item-attr "last-chain-day-index"
               (if (> done 0)
                   day-index
                 last-chain-day-index)))
     item-attr)))

(defun org-catalyst--get-earliest-month-day ()
  "Return earliest month-day of all histories.
If undefined, will attempt to calculate from files in save directory,
and fallback to current month-day."
  (or org-catalyst--earliest-month-day
      (setq
       org-catalyst--earliest-month-day
       (cons
        (let ((snapshot-month-days
               (mapcar
                (lambda (item)
                  (car
                   (org-catalyst--key-to-month-day
                    (substring (f-filename item) 0 7))))
                (f-glob (concat "*" org-catalyst--history-suffix)
                        org-catalyst-save-path))))
          (or
           (and snapshot-month-days
                (apply #'min snapshot-month-days))
           (car (org-catalyst--time-to-month-day))))
        0))))

(defun org-catalyst--maybe-set-earliest-month-day (month-day)
  "Set known earliest month-day to MONTH-DAY if existing value is later."
  (setq org-catalyst--earliest-month-day
        (cons
         (min (car (org-catalyst--get-earliest-month-day))
              (car month-day))
         0)))

(defun org-catalyst--maybe-set-earliest-modified-month-day (month-day)
  "Set known earliest-modified month-day to MONTH-DAY if existing value is later."
  (setq org-catalyst--earliest-modified-month-day
        (cons
         (if org-catalyst--earliest-modified-month-day
             (min (car org-catalyst--earliest-modified-month-day)
                  (car month-day))
           (car month-day))
         0)))

(defun org-catalyst--save-object (object file)
  "Save OBJECT to FILE."
  (unless (file-exists-p org-catalyst-save-path)
    (make-directory org-catalyst-save-path t))

  (unless (file-writable-p file)
    (error "File %s is not writable" file))

  (let ((json-object-type 'hash-table)
        (json-encoding-pretty-print t)
        (json-encoding-object-sort-predicate #'string<))
    (f-write-text (json-encode object) 'utf-8 file)))

(defun org-catalyst--load-object (file)
  "Load OBJECT from FILE."
  ;; NOTE: this is not efficient, but might handle encoding better.
  (when (file-exists-p file)
    (unless (file-readable-p file)
      (error "File %s is not readable" file))

    (let ((json-object-type 'hash-table))
      (json-read-from-string (f-read-text file 'utf-8)))))

(defun org-catalyst-has-unsaved-changes ()
  "Return if Catalyst has unsaved modifications."
  (or (not (ht-empty? org-catalyst--modified-snapshot-keys))
      (not (ht-empty? org-catalyst--modified-history-keys))))

(defun org-catalyst--time-to-month-day (&optional time zone)
  "Convert Emacs internal time representation TIME to month-day index representation."
  (let* ((decoded-time (decode-time time zone))
         (year (nth 5 decoded-time))
         (month (nth 4 decoded-time))
         (day-index (1- (nth 3 decoded-time)))
         (month-index (+ (* year 12) (1- month))))
    (cons month-index day-index)))

(defun org-catalyst--month-day-to-time (month-day &optional zone)
  "Convert MONTH-DAY index representation to Emacs internal time representation in time zone ZONE."
  (let* ((month-index (car month-day))
         (year (/ month-index 12))
         (month (1+ (- month-index (* year 12))))
         (day (1+ (cdr month-day))))
    (encode-time 0 0 0 day month year zone)))

(defun org-catalyst--month-day-to-days (month-day)
  "Convert MONTH-DAY to number of days since epoch."
  (round
   (/ (time-to-seconds
       (org-catalyst--month-day-to-time month-day t))
      86400.0)))

(defun org-catalyst--days-to-month-day (days)
  "Convert number of DAYS since epoch to month-day."
  (org-catalyst--time-to-month-day
   (seconds-to-time (* days 86400)) t))

(defun org-catalyst--month-day-days-delta (month-day-1 month-day-2)
  "Find the number of days elapsed between MONTH-DAY-1 and MONTH-DAY-2.
The return value is positive if MONTH-DAY-1 is before MONTH-DAY-2, and vice versa."
  (- (org-catalyst--month-day-to-days month-day-2)
     (org-catalyst--month-day-to-days month-day-1)))

(defun org-catalyst--read-month-day (&optional default-month-day)
  "Use org to read a month-day."
  (interactive)
  (org-catalyst--time-to-month-day
   (org-time-string-to-time
    (org-read-date nil nil nil "Go To"
                   (and default-month-day
                        (org-catalyst--month-day-to-time default-month-day))))))

(defun org-catalyst--month-day-to-key (month-day)
  "Convert a MONTH-DAY to key."
  (let* ((month-index (car month-day))
         (year (/ month-index 12))
         (month (1+ (- month-index (* year 12)))))
    (format "%04d-%02d" year month)))

(defun org-catalyst--get-days-in-month (month-index)
  "Get the number of days in the month at MONTH-INDEX."
  (let* ((year (/ month-index 12))
         (month (1+ (- month-index (* year 12)))))
    (calendar-last-day-of-month month year)))

(defun org-catalyst--month-day-to-day-key (month-day)
  "Convert a MONTH-DAY to key."
  (let* ((day (1+ (cdr month-day))))
    (format "%02d" day)))

(defun org-catalyst--key-to-month-day (key)
  "Convert a KEY to month-day."
  (let ((year (string-to-number (substring key 0 4)))
        (month (string-to-number (substring key 5 7))))
    (cons (+ (* year 12) (1- month)) 0)))

(defun org-catalyst--key-to-snapshot-path (key)
  "Return file path of the snapshot at time denoted by KEY."
  (f-join org-catalyst-save-path
          (concat key org-catalyst--snapshot-suffix)))

(defun org-catalyst--key-to-history-path (key)
  "Return file path of the history at time denoted by KEY."
  (f-join org-catalyst-save-path
          (concat key org-catalyst--history-suffix)))

(defun org-catalyst--map-entries (filter func)
  "TODO make the filter better"
  (org-map-entries func filter 'agenda))

(defun org-catalyst--get-config ()
  "TODO"
  ;; TODO: allow only getting parts of the things to optimize
  (let ((all-item-config (ht-create))
        (all-state-config (ht-create))
        (state-update-funcs (ht-create))
        (item-update-funcs (ht-create))
        (continuous-state-update-funcs (ht-create))
        (continuous-item-update-funcs (ht-create)))
    (org-catalyst--map-entries
     "item|state"
     (lambda ()
       (let ((tags org-scanner-tags))
         (cond

          ((member "item" tags)
           (let ((display-name (org-no-properties
                                (org-get-heading t t t t)))
                 (item-id (org-id-get-create))
                 (item-config (ht-create))
                 (state-deltas (ht-create))
                 (attributes nil)
                 (params (ht-create)))
             (dolist (prop (let ((org-trust-scanner-tags t))
                             (org-entry-properties (point)
                                                   'standard)))
               (let ((prop-name (downcase (car prop)))
                     (prop-value (cdr prop)))
                 (cond
                  ((string= prop-name "attributes")
                   (dolist (attribute
                            (split-string prop-value
                                          "[ \f\t\n\r\v]+"
                                          t))
                     (let* ((attribute (downcase
                                        (string-trim attribute)))
                            (system (ht-get org-catalyst--item-systems
                                            attribute)))
                       (setq attributes (cons attribute attributes))
                       (when system
                         (let ((continuous (ht-get system "continuous"))
                               (update-func (ht-get system "update-func")))
                           (let ((funcs-map (if continuous
                                                continuous-item-update-funcs
                                              item-update-funcs)))
                             (ht-set
                              funcs-map
                              item-id
                              (cons update-func
                                    (ht-get funcs-map item-id)))))))))

                  ((s-starts-with-p org-catalyst--state-delta-prefix
                                    prop-name)
                   ;; TODO: state names are stored in lower case
                   (ht-set state-deltas
                           (substring prop-name
                                      (length org-catalyst--state-delta-prefix))
                           (string-to-number prop-value)))

                  ((s-starts-with-p org-catalyst--param-prefix
                                    prop-name)
                   (ht-set params
                           (substring
                            prop-name
                            (length org-catalyst--param-prefix))
                           (car (read-from-string prop-value)))))))

             (ht-set item-config "display-name" display-name)
             (ht-set item-config "state-deltas" state-deltas)
             (ht-set item-config "attributes" attributes)
             (ht-set item-config "params" params)
             (ht-set all-item-config item-id
                     item-config)))

          ((member "state" tags)
           (let* ((display-name (org-no-properties
                                 (org-get-heading t t t t)))
                  (state-name (downcase display-name))
                  (state-config (ht-create))
                  (attributes nil)
                  (params (ht-create)))
             (dolist (prop (let ((org-trust-scanner-tags t))
                             (org-entry-properties (point)
                                                   'standard)))
               (let ((prop-name (downcase (car prop)))
                     (prop-value (cdr prop)))
                 (cond

                  ((string= prop-name "attributes")
                   (dolist (attribute
                            (split-string prop-value
                                          "[ \f\t\n\r\v]+"
                                          t))
                     (let* ((attribute (downcase
                                        (string-trim attribute)))
                            (system (ht-get org-catalyst--state-systems
                                            attribute)))
                       (setq attributes (cons attribute attributes))
                       (when system
                         (let ((continuous (ht-get system "continuous"))
                               (update-func (ht-get system "update-func")))
                           (let ((funcs-map (if continuous
                                                continuous-state-update-funcs
                                              state-update-funcs)))
                             (ht-set
                              funcs-map
                              state-name
                              (cons update-func
                                    (ht-get funcs-map state-name)))))))))

                  ((s-starts-with-p org-catalyst--param-prefix
                                    prop-name)
                   (ht-set params
                           (substring
                            prop-name
                            (length org-catalyst--param-prefix))
                           (car (read-from-string prop-value)))))))

             (ht-set state-config "display-name" display-name)
             (ht-set state-config "attributes" attributes)
             (ht-set state-config "params" params)
             (ht-set all-state-config state-name state-config)))))))

    (list :all-item-config all-item-config
          :all-state-config all-state-config
          :state-update-funcs state-update-funcs
          :item-update-funcs item-update-funcs
          :continuous-state-update-funcs continuous-state-update-funcs
          :continuous-item-update-funcs continuous-item-update-funcs)))

(defun org-catalyst--update-function (snapshot
                                      actions
                                      month-day
                                      all-item-config
                                      all-state-config
                                      state-update-funcs
                                      item-update-funcs
                                      continuous-state-update-funcs
                                      continuous-item-update-funcs)
  "TODO
NOTE: This function can mutate SNAPSHOT."
  (let ((state-attributes (ht-get snapshot "state-attributes"))
        (item-attributes (ht-get snapshot "item-attributes"))
        (empty-table (ht-create))
        (state-updates (ht-create)))
    ;; TODO: consider the amount of action done
    ;; reactive update
    (dolist (item-id (ht-keys actions))
      (let* ((action (ht-get actions item-id empty-table))
             (item-config (ht-get all-item-config item-id))
             (state-deltas
              (and item-config
                   (ht-get item-config "state-deltas")))
             (item-params
              (or (and item-config
                       (ht-get item-config "params"))
                  empty-table)))
        (when state-deltas
          (dolist (state-name (ht-keys state-deltas))
            (let* ((state-config (ht-get all-state-config state-name))
                   (state-params (or (and
                                      state-config
                                      (ht-get state-config "params"))
                                     empty-table))
                   (delta (ht-get state-deltas state-name)))
              (ht-set state-updates state-name
                      (cons (cons action delta)
                            (ht-get state-updates state-name)))
              (dolist (state-update-func (ht-get state-update-funcs
                                                 state-name))
                (ht-set state-attributes
                        state-name
                        (funcall
                         state-update-func
                         (or (ht-get state-attributes state-name)
                             (ht-create))
                         action
                         delta
                         month-day
                         state-params))))))
        (dolist (item-update-func (ht-get item-update-funcs item-id))
          (ht-set item-attributes
                  item-id
                  (funcall
                   item-update-func
                   (or (ht-get item-attributes item-id)
                       (ht-create))
                   action
                   month-day
                   item-params)))))

    ;; continuous update

    (dolist (item-id (ht-keys continuous-item-update-funcs))
      (let* ((action (ht-get actions item-id empty-table))
             (item-config (ht-get all-item-config item-id))
             (item-params
              (or (and item-config
                       (ht-get item-config "params"))
                  empty-table)))
        (dolist (item-update-func (ht-get continuous-item-update-funcs
                                          item-id))
          (ht-set item-attributes
                  item-id
                  (funcall
                   item-update-func
                   (or (ht-get item-attributes item-id)
                       (ht-create))
                   action
                   month-day
                   item-params)))))

    (dolist (state-name (ht-keys continuous-state-update-funcs))
      (let* ((state-config (ht-get all-state-config state-name))
             (state-params
              (or (and state-config
                       (ht-get state-config "params"))
                  empty-table)))
        (dolist (state-update-func (ht-get continuous-state-update-funcs
                                           state-name))
          (ht-set state-attributes
                  state-name
                  (funcall
                   state-update-func
                   (or (ht-get state-attributes state-name)
                       (ht-create))
                   (ht-get state-updates state-name)
                   month-day
                   state-params)))))

    snapshot))

(defun org-catalyst--new-snapshot ()
  "Construct a new empty snapshot."
  (let ((snapshot (ht-create)))
    (ht-set snapshot "state-attributes" (ht-create))
    (ht-set snapshot "item-attributes" (ht-create))
    snapshot))

(defun org-catalyst--new-actions ()
  "Construct a new empty actions."
  (ht-create))

(defun org-catalyst--new-history ()
  "Construct a new empty history."
  (ht-create))

(defun org-catalyst--save-snapshot (key snapshot)
  "Save the given KEY and SNAPSHOT to disk."
  (org-catalyst--save-object
   snapshot
   (org-catalyst--key-to-snapshot-path key)))

(defun org-catalyst--save-history (key history)
  "Save the given KEY and HISTORY to disk."
  (org-catalyst--save-object
   history
   (org-catalyst--key-to-history-path key)))

(defun org-catalyst--emacs-quit-query-function ()
  "Ask the user for game save before quitting Emacs."
  (if (and
       (org-catalyst-has-unsaved-changes)
       (let ((org-catalyst--inhibit-save t))
         (y-or-n-p "You have unsaved changes in org-catalyst.  Save game? ")))
      (progn
        (org-catalyst-save-game)
        t)
    t)) ;; only fails on keyboard quit or error

(defun org-catalyst--next-month-day (month-day)
  "Return the day after MONTH-DAY."
  (let ((month-index (car month-day))
        (day-index (cdr month-day)))
    (if (>= day-index (org-catalyst--get-days-in-month month-index))
        (cons (1+ month-index) 0)
      (cons month-index (1+ day-index)))))

(defun org-catalyst--get-history-containing (month-day)
  "Return the history object containing MONTH-DAY."
  (let ((key (org-catalyst--month-day-to-key month-day)))
    (if (org-catalyst--lru-contains org-catalyst--buffered-histories key)
        (org-catalyst--lru-get org-catalyst--buffered-histories key)
      (let ((history (or
                      (org-catalyst--load-object
                       (org-catalyst--key-to-history-path key))
                      (org-catalyst--new-history))))
        (org-catalyst--lru-set
         org-catalyst--buffered-histories key
         history)
        history))))

(defun org-catalyst--get-actions-at (month-day)
  "Return the actions at MONTH-DAY."
  (let ((day-key (org-catalyst--month-day-to-day-key month-day))
        (history (org-catalyst--get-history-containing month-day)))
    (if (ht-contains-p history day-key)
        (ht-get history day-key)
      (let ((actions (org-catalyst--new-actions)))
        (ht-set history day-key actions)
        actions))))

(defun org-catalyst--deep-copy (object)
  "Make a deep copy of OBJECT.
This is similar to `copy-tree', but handles hash tables as well."

  (cond
   ((consp object)
    (let (result)
      (while (consp object)
        (let ((newcar (car object)))
          (if (or (consp (car object))
                  (vectorp (car object)))
              (setq newcar (org-catalyst--deep-copy (car object))))
          (push newcar result))
        (setq object (cdr object)))
      (nconc (nreverse result) object)))

   ((hash-table-p object)
    ;; Reference:
    ;; http://www.splode.com/~friedman/software/emacs-lisp/src/deep-copy.el
    (let ((new-table
           (make-hash-table
            :test             (hash-table-test             object)
            :size             (hash-table-size             object)
            :rehash-size      (hash-table-rehash-size      object)
            :rehash-threshold (hash-table-rehash-threshold object)
            :weakness         (hash-table-weakness         object))))
      (maphash (lambda (key value)
                 (puthash (org-catalyst--deep-copy key)
                          (org-catalyst--deep-copy value)
                          new-table))
               object)
      new-table))

   ((vectorp object)
    (let ((i (length (setq object (copy-sequence object)))))
      (while (>= (setq i (1- i)) 0)
        (aset object i (org-catalyst--deep-copy (aref object i))))
      object))

   (t
    object)))

(defun org-catalyst--compute-snapshot-at (month-day &optional config)
  "Return the snapshot value at the start of MONTH-DAY.
It is ensured that the snapshot returned is a deep copy.

If CONFIG is non-nil, it is used instead of computing another."
  (org-catalyst--ensure-snapshots-correctness config)
  (org-catalyst--deep-copy
   (let ((month-index (car month-day))
         (day-index (cdr month-day))
         (config (or config
                     (org-catalyst--get-config-with-cache))))
     (if (= day-index 0) ; start of the month
         (if (>= month-index (car (org-catalyst--get-earliest-month-day)))
             (let ((key (org-catalyst--month-day-to-key month-day)))
               (if (org-catalyst--lru-contains
                    org-catalyst--buffered-snapshots
                    key)
                   (org-catalyst--lru-get org-catalyst--buffered-snapshots
                                          key)
                 (let ((snapshot (org-catalyst--load-object
                                  (org-catalyst--key-to-snapshot-path key))))
                   (if snapshot
                       (org-catalyst--update-cached-snapshot
                        month-day snapshot t)
                     (setq snapshot (org-catalyst--compute-snapshot-at
                                     (cons
                                      (1- month-index)
                                      (org-catalyst--get-days-in-month
                                       (1- month-index)))
                                     config))
                     (org-catalyst--update-cached-snapshot month-day
                                                           snapshot))
                   snapshot)))
           (org-catalyst--new-snapshot))
       ;; other days of the month
       (let* ((all-item-config (plist-get config :all-item-config))
              (all-state-config (plist-get config :all-state-config))
              (state-update-funcs (plist-get config :state-update-funcs))
              (item-update-funcs (plist-get config :item-update-funcs))
              (continuous-state-update-funcs
               (plist-get config :continuous-state-update-funcs))
              (continuous-item-update-funcs
               (plist-get config :continuous-item-update-funcs))
              (cur-day-index 0)
              (cur-snapshot (org-catalyst--compute-snapshot-at
                             (cons month-index 0)
                             config)))
         (while (< cur-day-index day-index)
           (let ((cur-month-day (cons month-index cur-day-index)))
             (setq cur-snapshot
                   (org-catalyst--update-function
                    cur-snapshot
                    (org-catalyst--get-actions-at
                     cur-month-day)
                    (cons month-index (1+ cur-day-index))
                    all-item-config
                    all-state-config
                    state-update-funcs
                    item-update-funcs
                    continuous-state-update-funcs
                    continuous-item-update-funcs)))
           (setq cur-day-index (1+ cur-day-index)))
         cur-snapshot)))))

(defun org-catalyst--compute-snapshot-after (month-day &optional config)
  "Return the snapshot value at the end of MONTH-DAY.

If CONFIG is non-nil, it is used instead of computing another."
  (let ((config (or config
                    (org-catalyst--get-config-with-cache))))
    (org-catalyst--compute-snapshot-at
     (org-catalyst--next-month-day month-day)
     config)))

(defun org-catalyst--update-cached-snapshot (month-day snapshot &optional no-mark-modified)
  "Set cached snapshot object at MONTH-DAY to SNAPSHOT.
If NO-MARK-MODIFIED is nil, KEY will be marked as modified,
 and will be saved when `org-catalyst-save-game' is called."
  (let ((key (org-catalyst--month-day-to-key month-day)))
    (org-catalyst--lru-set org-catalyst--buffered-snapshots
                           key snapshot)
    (unless no-mark-modified
      (ht-set org-catalyst--modified-snapshot-keys key t))))

(defun org-catalyst--update-cached-snapshots (month-day &optional config)
  "Update all cached snapshots as if edits were made during MONTH-DAY.

If CONFIG is non-nil, it is used instead of computing another."
  (let ((config (or config
                    (org-catalyst--get-config-with-cache)))
        (cur-month-index (1+ (car month-day)))
        (now-month-index (car (org-catalyst--time-to-month-day))))
    (while (<= cur-month-index now-month-index)
      (org-catalyst--update-cached-snapshot
       (cons cur-month-index 0)
       (org-catalyst--compute-snapshot-at
        (cons (1- cur-month-index)
              (org-catalyst--get-days-in-month
               (1- cur-month-index)))
        config))
      (setq cur-month-index (1+ cur-month-index)))))

(defun org-catalyst--ensure-snapshots-correctness (&optional config)
  "Update all snapshots to ensure they are correct.
This is provided that all modifications were made in org-catalyst.

If CONFIG is non-nil, it is used instead of computing another."
  (when (and org-catalyst--earliest-modified-month-day
             (not org-catalyst--computing-snapshot))
    (let ((earliest-modified-month-day
           org-catalyst--earliest-modified-month-day)
          (org-catalyst--computing-snapshot t)
          (config (or config
                      (org-catalyst--get-config-with-cache))))
      (org-catalyst--update-cached-snapshots
       earliest-modified-month-day
       config)
      (setq org-catalyst--earliest-modified-month-day nil))))

(defun org-catalyst--save-window-configuration ()
  "Save the current window configuration.
Note that the configuration is saved locally to the current buffer."
  (unless (get-buffer-window (current-buffer) (selected-frame))
    (setq-local org-catalyst--prev-window-conf
                (current-window-configuration))))

(defun org-catalyst--restore-window-configuration ()
  "Restore previous window configuration."
  (let ((winconf org-catalyst--prev-window-conf)
        (buffer (current-buffer))
        (frame (selected-frame)))
    ;; TODO: this allows killing buffer by setting second arg to t
    (quit-window nil (selected-window))
    (when (and winconf (equal frame (window-configuration-frame winconf)))
      (set-window-configuration winconf)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq-local org-catalyst--prev-window-conf nil))))))

(defun org-catalyst--display-action-fullframe (buffer alist)
  "Action for `display-buffer' that displays in fullframe."
  (when-let ((window (or (display-buffer-reuse-window buffer alist)
                         (display-buffer-same-window buffer alist)
                         (display-buffer-pop-up-window buffer alist)
                         (display-buffer-use-some-window buffer alist))))
    (delete-other-windows window)
    window))

(defun org-catalyst--display-buffer-fullframe (buffer)
  "Display BUFFER in fullframe."
  (display-buffer buffer '(org-catalyst--display-action-fullframe)))

(defmacro org-catalyst--define-renderer (name inputs &rest body)
  "Define a Catalyst renderer with NAME.

Define a function with BODY that accepts INPUTS as keyword argument.
The first element of BODY can be the docstring."
  (declare (indent 2) (doc-string 3))
  `(cl-defun ,name (&key ,@inputs &allow-other-keys)
     ,@body))

(defmacro org-catalyst--inline-renderer (inputs &rest body)
  "Define an inline Catalyst renderer.

Return a function with BODY that accepts INPUTS as keyword argument."
  (declare (indent 1))
  `(cl-function
    (lambda (&key ,@inputs &allow-other-keys)
      ,@body)))

(defmacro org-catalyst--partial-renderer (renderer &rest inputs)
  "Define a partial function of RENDERER.

Return RENDERER with INPUTS already fed as argument."
  `(lambda (&rest rest)
     (apply (quote ,name) ,@inputs rest)))

(defun org-catalyst--number-to-string (number)
  "Convert NUMBER to a display string.

If the value of NUMBER is an integer, no decimal point will be displayed."
  (let ((rounded (round number)))
    (if (= rounded number)
        (number-to-string rounded)
      (let ((number (round number 0.01)))
        (cond ((= (% number 100) 0)
               (number-to-string (round (* number 0.01))))
              ((= (% number 10) 0)
               (format "%.1f" (* number 0.01)))
              (t
               (format "%.2f" (* number 0.01))))))))

(defun org-catalyst--get-ui-data (config)
  "Extract data from CONFIG for use in status window."
  (let ((attribute-to-items (ht-create))
        (attribute-to-states (ht-create)))

    (ht-map
     (lambda (item-id item-config)
       (let ((attributes (ht-get item-config "attributes")))
         (dolist (attribute attributes)
           (ht-set attribute-to-items
                   attribute
                   (cons item-id
                         (ht-get attribute-to-items
                                 attribute))))))

     (plist-get config :all-item-config))

    (ht-map
     (lambda (state-name state-config)
       (let ((attributes (ht-get state-config "attributes")))
         (dolist (attribute attributes)
           (ht-set attribute-to-states
                   attribute
                   (cons state-name
                         (ht-get attribute-to-states
                                 attribute))))))

     (plist-get config :all-state-config))

    (ht<-alist (list
                (cons "attribute-to-items" attribute-to-items)
                (cons "attribute-to-states" attribute-to-states)))))

(defun org-catalyst--get-item-attribute (snapshot item-id prop &optional default)
  "Return the attribute with name PROP for item with ITEM-ID in SNAPSHOT.

Use DEFAULT when the value is not found."
  (let* ((item-attributes (ht-get snapshot "item-attributes"))
         (item-attr (ht-get item-attributes item-id)))
    (or (and item-attr
             (ht-get item-attr prop))
        default)))

(defun org-catalyst--inf-to-number (number)
  "Convert NUMBER to 1.0e+INF if NUMBER is \"inf\", otherwise return NUMBER."
  (if (equal number "inf")
      1.0e+INF
    number))

(defun org-catalyst--get-state-attribute (snapshot state-name prop &optional default)
  "Return the attribute with name PROP for state with STATE-NAME in SNAPSHOT.

Use DEFAULT when the value is not found."
  (let* ((state-attributes (ht-get snapshot "state-attributes"))
         (state-attr (ht-get state-attributes state-name)))
    (or (and state-attr
             (ht-get state-attr prop))
        default)))

(org-catalyst--define-renderer org-catalyst--render-section-heading
    (name face)
  (insert
   (propertize name
               'face (or face
                         'org-catalyst-section-heading-face))
   "\n"))

(org-catalyst--define-renderer org-catalyst--render-sorted
    (renderer-alist (reverse nil) (comp #'<))
  "Render cdr of each element in RENDERER-ALIST, with car as the order.

REVERSE the order if REVERSE is non-nil."
  (let ((sorted-renderers
         (sort
          (copy-sequence renderer-alist)
          (if reverse
              (lambda (a b)
                (funcall comp (car b) (car a)))
            (lambda (a b)
              (funcall comp (car a) (car b)))))))
    (dolist (renderer sorted-renderers)
      (funcall (cdr renderer)))))

(org-catalyst--define-renderer org-catalyst-section-separator
    ()
  (insert "\n"))

(org-catalyst--define-renderer org-catalyst-section-overview
    (month-day
     today-month-day)
  (let ((is-today (equal month-day today-month-day)))
    (insert (propertize
             (concat
              (format-time-string org-catalyst-status-today-format
                                  (org-catalyst--month-day-to-time
                                   month-day))
              (if is-today
                  " [TODAY]"
                ""))
             'face 'org-catalyst-today-face)
            "\n")))

(org-catalyst--define-renderer org-catalyst--render-leveled-value
    (value)
  (let* ((level-and-threshold (org-catalyst--get-level-and-threshold
                               value))
         (level (car level-and-threshold))
         (threshold (cdr level-and-threshold)))
    (insert (format "Lv.%s %-8s"
                    (if level
                        (org-catalyst--number-to-string level)
                      "∞")
                    (if level
                        (concat
                         (org-catalyst--number-to-string value)
                         "/"
                         (org-catalyst--number-to-string threshold))
                      "")))))

(org-catalyst--define-renderer org-catalyst--render-delta-desc
    (item-config)
  (let ((state-deltas (org-catalyst-safe-get item-config "state-deltas" nil)))
    (when (and state-deltas
               (not (ht-empty? state-deltas)))
      (insert
       (propertize
        (concat "["
                (s-join
                 ", "
                 (ht-map
                  (lambda (state-name delta)
                    (let ((size (length state-name))
                          (abbrev-size 3))
                      (concat (if (< delta 0)
                                  ""
                                "+")
                              (org-catalyst--number-to-string delta)
                              " "
                              (capitalize
                               (substring state-name 0
                                          (min abbrev-size
                                               size)))
                              (if (> size abbrev-size)
                                  "."
                                ""))))
                  state-deltas))
                "]")
        'face 'org-catalyst-state-delta-face)))))

(org-catalyst--define-renderer org-catalyst--render-item
    (action
     item-config)
  (let* ((params (org-catalyst-safe-get
                  item-config "params" nil))
         (display-name (org-catalyst-safe-get
                        item-config "display-name" "(no name)"))
         (timed (org-catalyst-safe-get
                 params "timed" nil))
         (negative (org-catalyst-safe-get
                    params "negative" nil))
         (done (org-catalyst-safe-get
                action "done" 0))
         (pardon (org-catalyst-safe-get
                  action "pardon" 0))
         (done-face (if negative
                        'org-catalyst-negative-done-face
                      'org-catalyst-done-face)))
    (insert (cond ((and timed (> done 0))
                   (concat
                    (propertize
                     (concat
                      "[" (org-catalyst--number-to-string done)
                      "]")
                     'face done-face)
                    " "))
                  ((> done 0)
                   (concat
                    (propertize "[✓]" 'face
                                done-face)
                    " "))
                  ((> pardon 0)
                   (concat
                    (propertize "[P]" 'face
                                'org-catalyst-pardon-face)
                    " "))
                  ((and negative (<= done 0))
                   (concat
                    (propertize "[×]" 'face
                                'org-catalyst-done-face)
                    " "))
                  (t
                   ""))
            display-name
            "\t")
    (org-catalyst--render-delta-desc :item-config item-config)
    (insert "\n")))

(org-catalyst--define-renderer org-catalyst-section-accumulated-stats
    (config
     snapshot
     ui-data)
  (let* ((all-state-config (plist-get config :all-state-config))
         (state-attributes (ht-get snapshot "state-attributes"))
         (attribute-to-states (org-catalyst-safe-get
                               ui-data "attribute-to-states"
                               (ht-create))))
    ;; TODO: also refactor to get a list of state/item with attributes
    ;; handle sorting as well

    (org-catalyst--render-section-heading :name "Stats")

    (org-catalyst--render-sorted
     :reverse t
     :renderer-alist
     (mapcar
      (lambda (state-name)
        (let* ((total (org-catalyst--get-state-attribute
                       snapshot state-name "total" 0))
               ;; TODO: can refactor to use a macro for chained access, returning default
               (state-config (ht-get all-state-config state-name))
               (display-name (ht-get state-config "display-name")))

          (cons
           (org-catalyst--inf-to-number total)
           (org-catalyst--inline-renderer ()
             (org-catalyst--render-leveled-value :value total)
             (insert (format " %s\n" display-name))))))
      (org-catalyst-safe-get
       attribute-to-states "total"
       nil)))))

(org-catalyst--define-renderer org-catalyst-section-journal
    (config
     snapshot
     month-day)
  (org-catalyst--render-section-heading :name "Journal")

  (let* ((actions (org-catalyst--get-actions-at month-day))
         (all-item-config (plist-get config :all-item-config))
         (all-state-config (plist-get config :all-state-config)))
    (org-catalyst--render-sorted
     :reverse t
     :renderer-alist
     (let ((renderers nil))
       (ht-map
        (lambda (item-id action)
          (let* ((item-config
                  (org-catalyst-safe-get all-item-config item-id nil))
                 (chain (org-catalyst--get-item-attribute
                         snapshot item-id "chain" 0))
                 (display-name
                  (org-catalyst-safe-get item-config "display-name" nil))
                 (timed (org-catalyst-safe-get
                         (org-catalyst-safe-get
                          item-config "params" nil)
                         "timed" nil))
                 (done (org-catalyst-safe-get
                        action "done" 0))
                 (pardon (org-catalyst-safe-get
                          action "pardon" 0)))
            (when (or (> done 0)
                      (> pardon 0))
              (push
               (cons
                done
                (org-catalyst--inline-renderer ()
                  (org-catalyst--render-leveled-value
                   :value chain)
                  (insert " ")
                  (org-catalyst--render-item
                   :action action
                   :item-config item-config)))
               renderers))))
        actions)
       renderers))))

(cl-defun org-catalyst-section-chains
    (&key
     config
     ui-data
     month-day
     snapshot
     &allow-other-keys)

  ;; TODO can add to ui-data for caching
  (let* ((attribute-to-items (org-catalyst-safe-get ui-data
                                                    "attribute-to-items"
                                                    (ht-create)))
         (item-ids (ht-get attribute-to-items "chain"))
         (actions (org-catalyst--get-actions-at month-day))
         (all-item-config (plist-get config :all-item-config))
         (all-state-config (plist-get config :all-state-config))
         (item-attributes (ht-get snapshot "item-attributes"))
         (row-data
          (mapcar
           (lambda (item-id)
             (let* ((item-config (ht-get all-item-config item-id))
                    (chain (org-catalyst--get-item-attribute
                            snapshot item-id "chain" 0))
                    (last-chain-day-index
                     (org-catalyst--get-item-attribute
                      snapshot item-id "last-chain-day-index" 1))
                    (day-index
                     (1+ (org-catalyst--month-day-to-days month-day)))
                    (days-since-last
                     (- day-index
                        last-chain-day-index))
                    ;; TODO: customizable default chain interval. in update function too.
                    (params (org-catalyst-safe-get
                             item-config "params" nil))
                    (action (org-catalyst-safe-get
                             actions item-id nil))
                    (chain-interval
                     (org-catalyst-safe-get params
                                            "chain_interval" 1))
                    (breaking
                     (= days-since-last chain-interval)))
               (list :item-id item-id
                     :chain (org-catalyst--inf-to-number chain)
                     :breaking breaking
                     :item-config item-config
                     :action action)))
           item-ids)))

    (let ((rows (sort
                 (seq-filter (lambda (row)
                               (plist-get row :breaking))
                             row-data)
                 (lambda (a b)
                   (> (plist-get a :chain)
                      (plist-get b :chain))))))
      (when rows
        (org-catalyst--render-section-heading
         :name "Breaking Chains"
         :face 'org-catalyst-section-heading-warning-face)

        (dolist (row rows)
          ;; TODO: render row.
          (org-catalyst--render-leveled-value
           :value (plist-get row :chain))
          (insert " ")
          (org-catalyst--render-item
           :action (plist-get row :action)
           :item-config (plist-get row :item-config)))

        (org-catalyst-section-separator)))

    (let ((rows (sort
                 row-data
                 (lambda (a b)
                   (> (plist-get a :chain)
                      (plist-get b :chain))))))
      (org-catalyst--render-section-heading :name "Top Chains")
      (dolist (row rows)
        (org-catalyst--render-leveled-value
         :value (plist-get row :chain))
        (insert " ")
        (org-catalyst--render-item
         :action (plist-get row :action)
         :item-config (plist-get row :item-config))))))

(defun org-catalyst-setup-default-sections ()
  "Set `org-catalyst-status-sections' to be a good default."
  ;; TODO
  (setq org-catalyst-status-sections
        '(overview
          separator
          accumulated-stats
          separator
          journal
          separator
          chains)))

(defun org-catalyst--render-status ()
  ;; TODO
  "Render status window."
  (let* ((config (org-catalyst--get-config-with-cache))
         (ui-data (org-catalyst--get-ui-data config))
         (month-day org-catalyst--status-month-day)
         (snapshot (org-catalyst--compute-snapshot-after
                    month-day
                    config)))
    (dolist (section org-catalyst-status-sections)
      (funcall
       ;; TODO pull to constant
       (intern (concat "org-catalyst-section-"
                       (symbol-name section)))
       :config config
       :ui-data ui-data
       :month-day month-day
       :today-month-day (org-catalyst--status-today-month-day)
       :snapshot snapshot))))

(defun org-catalyst--in-status-buffer ()
  "Return t if currently in Catalyst status buffer."
  (eq (get-buffer org-catalyst-buffer-name)
      (current-buffer)))

;; TODO: can make a macro to allow chaining function call syntax

(defmacro org-catalyst--update-actions (month-day &rest body)
  "Evaluate BODY, which should update the actions at MONTH-DAY.
The actions object at MONTH-DAY will be bound to `actions'.
This marks the history containing MONTH-DAY as modified, and will perform
update on all cache after MONTH-DAY."
  `(let ((actions (org-catalyst--get-actions-at ,month-day)))
     ,@body
     (org-catalyst--maybe-set-earliest-month-day ,month-day)
     (org-catalyst--maybe-set-earliest-modified-month-day ,month-day)
     (ht-set org-catalyst--modified-history-keys
             (org-catalyst--month-day-to-key ,month-day) t)))

(defun org-catalyst--invalidate-config-cache ()
  "Invalid cache for config in status buffer."
  (setq org-catalyst--config-cache-valid nil))

(defun org-catalyst--get-config-with-cache ()
  "Return a list of all items, for use with completion.

When currently in status buffer, this list is cached until refresh."
  (if (and (org-catalyst--in-status-buffer)
           org-catalyst--config-cache-valid)
      org-catalyst--cached-config
    (setq
     org-catalyst--config-cache-valid t
     org-catalyst--cached-config
     (org-catalyst--get-config))))

(defun org-catalyst--select-item (prompt)
  "Select an action using minibuffer using PROMPT."
  (get-text-property
   0
   'property
   (completing-read
    prompt
    (ht-map (lambda (item-id item-config)
              (propertize
               (org-catalyst-safe-get item-config "display-name"
                                      "(no name)")
               'property
               item-id))
            (plist-get (org-catalyst--get-config-with-cache)
                       :all-item-config))
    nil ; predicate
    t ; require-match
    nil ; initial-input
    'org-catalyst--select-item-history)))

(defmacro org-catalyst--interactively-update-item (prompt arg &rest body)
  "Update item interactively.

Interactively select an action with PROMPT and run BODY that update the item
action at a certain date.

The existing value of the item action will be bound to `action'.

The ID of selected item will be bound to `item-id', all actions at the
selected date will be bound to `actions', and parameters of the item will be
bound to `params'.

BODY should modify `action' (which is a hash table).

If currently not in status window or if ARG is non-nil, the date will be
interactively selected.
Otherwise, the date will be the current day in the status window."
  `(let* ((in-status-buffer (org-catalyst--in-status-buffer))
          (month-day (if (or ,arg
                             (not in-status-buffer))
                         (org-catalyst--read-month-day
                          org-catalyst--status-month-day)
                       org-catalyst--status-month-day))
          (item-id
           (org-catalyst--select-item ,prompt))
          (params (org-catalyst-safe-get
                   (org-catalyst-safe-get
                    (plist-get
                     (org-catalyst--get-config-with-cache)
                     :all-item-config)
                    item-id nil)
                   "params" (ht-create))))
     (org-catalyst--update-actions
      month-day
      (org-catalyst-safe-update
       actions item-id (ht-create)
       (lambda (action)
         ,@body
         action)))
     (when in-status-buffer
       (org-catalyst-status-refresh))))

(defun org-catalyst--default-level-function (level)
  "Default level function.  Return required amount at LEVEL."
  (+ 2 (* level 1)))

(defun org-catalyst--get-level-and-threshold (value)
  "Return level at VALUE, using `org-catalyst-level-function'."
  (if (or (equal value "inf")
          (equal value 1.0e+INF))
      nil
    (let ((level 1)
          (threshold 0))
      (while (and (>= value
                      (setq threshold
                            (+ threshold
                               (funcall org-catalyst-level-function
                                        level))))
                  (< level org-catalyst-max-level))
        (setq level (1+ level)))
      (cons level threshold))))

(defun org-catalyst--status-today-month-day ()
  "Return the month-day for \"today\" for use in status buffer.

This takes `org-catalyst-day-start-hour' into account."
  (org-catalyst--time-to-month-day
   (time-add (current-time)
             (* -3600
                org-catalyst-day-start-hour))))

;;; Commands

(defun org-catalyst-complete-item-toggle (&optional arg)
  "TODO"
  (interactive "P")
  (org-catalyst--interactively-update-item
   "Complete item: " arg
   (if (org-catalyst-safe-get params "timed" nil)
       ;; timed
       (let ((amount (read-number "Enter amount: ")))
         (if (<= amount 0)
             (ht-remove action "done")
           (ht-set action "done" amount)))
     ;; not timed
     (if (> (org-catalyst-safe-get action "done" 0) 0)
         (ht-remove action "done")
       (ht-set action "done" 1)))))

(defun org-catalyst-pardon-item-toggle (&optional arg)
  "TODO"
  (interactive "P")
  (org-catalyst--interactively-update-item
   "Pardon item: " arg
   (if (> (org-catalyst-safe-get action "pardon" 0) 0)
       (ht-remove action "pardon")
     (ht-set action "pardon" 1))))

(defun org-catalyst-recompute-history ()
  "Recompute all snapshots from the entire history."
  (interactive)
  ;; NOTE: probably update some view?
  (org-catalyst--update-cached-snapshots
   (org-catalyst--get-earliest-month-day))
  (message "Recomputed Catalyst history."))

(defun org-catalyst-update-inline-info ()
  "TODO"
  (interactive))

(defun org-catalyst-save-game ()
  "Save the current game state."
  (interactive)
  (unless org-catalyst--inhibit-save
    (let ((game-saved nil))

    (unless (ht-empty? org-catalyst--modified-history-keys)
      (dolist (key (ht-keys org-catalyst--modified-history-keys))
        (let ((history (or (org-catalyst--lru-get
                            org-catalyst--buffered-histories key)
                           (org-catalyst--new-history))))
          (org-catalyst--save-history key history)))
      (ht-clear org-catalyst--modified-history-keys)
      (org-catalyst--lru-evict org-catalyst--buffered-histories
                               org-catalyst-history-cache-size)
      (org-catalyst--ensure-snapshots-correctness)
      (setq game-saved t))

    (unless (ht-empty? org-catalyst--modified-snapshot-keys)
      (dolist (key (ht-keys org-catalyst--modified-snapshot-keys))
        (let ((snapshot (or (org-catalyst--lru-get
                             org-catalyst--buffered-snapshots key)
                            (org-catalyst--new-snapshot))))
          (org-catalyst--save-snapshot key snapshot)))
      (ht-clear org-catalyst--modified-snapshot-keys)
      (org-catalyst--lru-evict org-catalyst--buffered-snapshots
                               org-catalyst-snapshot-cache-size)
      (setq game-saved t))

    (when game-saved
      (message "org-catalyst game saved.")))))

(defun org-catalyst-status-refresh (&optional invalidate-cache)
  "Refresh Catalyst window.

When called interactively, or when INVALIDATE-CACHE is non-nil, config cache
will be invalidated."
  (interactive)
  ;; TODO: is this the best idea
  (if (org-catalyst--in-status-buffer)
      (let ((line (org-current-line))
            (inhibit-read-only t))
        (when (or invalidate-cache
                  (called-interactively-p 'any))
          (org-catalyst--invalidate-config-cache))
        (erase-buffer)
        (org-catalyst--render-status)
        (org-goto-line line))
    (error "Not in Catalyst buffer")))

(defun org-catalyst-status-quit ()
  "Quit Catalyst window."
  (interactive)
  (if (org-catalyst--in-status-buffer)
      (org-catalyst--restore-window-configuration)
    (error "Not in Catalyst buffer")))

(defun org-catalyst-status-goto-date ()
  "Jump to a date in the Catalyst window."
  (interactive)
  (if (org-catalyst--in-status-buffer)
      ;; TODO maybe stop snapshots from generating after a certain time, and not allow user to go there
      (let ((month-day (org-catalyst--read-month-day
                        org-catalyst--status-month-day)))
        (setq-local org-catalyst--status-month-day
                    month-day)
        (org-catalyst-status-refresh))
    (error "Not in Catalyst buffer")))

(defun org-catalyst-status-goto-today ()
  "Jump to today in the Catalyst window.

Note that this invalidates config cache."
  (interactive)
  (if (org-catalyst--in-status-buffer)
      (progn
        (setq-local org-catalyst--status-month-day
                    (org-catalyst--status-today-month-day))
        (org-catalyst-status-refresh))
    (error "Not in Catalyst buffer")))

(defun org-catalyst-status-later (&optional count)
  "Jump to COUNT days later in the Catalyst window."
  (interactive "p")
  (if (org-catalyst--in-status-buffer)
      (let ((count (or count 1)))
        (setq-local
         org-catalyst--status-month-day
         (org-catalyst--days-to-month-day
          (+ count
             (org-catalyst--month-day-to-days
              org-catalyst--status-month-day))))
        (org-catalyst-status-refresh))
    (error "Not in Catalyst buffer")))

(defun org-catalyst-status-earlier (&optional count)
  "Jump to COUNT days earlier in the Catalyst window."
  (interactive "p")
  (org-catalyst-status-later (- (or count 1))))

(defun org-catalyst-status ()
  "Open Catalyst status window."
  (interactive)
  ;; TODO make quit window and start window customizable
  (let ((buffer (get-buffer-create org-catalyst-buffer-name)))
    (unless buffer
      (error "Open Catalyst buffer failed"))

    (unless (eq buffer (current-buffer))
      (with-current-buffer buffer
        (org-catalyst--save-window-configuration))

      (let ((window (funcall org-catalyst-display-buffer-function buffer)))
        (let* ((old-frame (selected-frame))
               (new-frame (window-frame window)))
          (select-window window)
          (unless (eq old-frame new-frame)
            (select-frame-set-input-focus new-frame))

          (org-catalyst-mode)
          (goto-char (point-min))
          (org-catalyst--invalidate-config-cache)
          (org-catalyst-status-goto-today))))))

;;; Minor modes

(define-minor-mode org-catalyst-auto-save-mode
  "Automatically save Catalyst game."
  :init-value nil
  :global t
  :group 'org-catalyst

  (when (not org-catalyst-auto-save-mode) ;; OFF
    (cancel-timer org-catalyst--auto-save-timer)
    (remove-hook 'kill-emacs-query-functions
                 #'org-catalyst--emacs-quit-query-function))

  (when org-catalyst-auto-save-mode ;; ON
    (setq org-catalyst--auto-save-timer
          (run-with-idle-timer org-catalyst-auto-save-idle-delay t
                               #'org-catalyst-save-game))
    (add-hook 'kill-emacs-query-functions
              #'org-catalyst--emacs-quit-query-function)))

;;; Major modes

;; TODO: decide between `make-sparse-keymap' and `make-keymap'
;; TODO: evil integration. maybe motion only (will need to make sure q is not used in motion).
;; or manually set every evil key.
(defvar org-catalyst-mode-map
  (let ((map (make-sparse-keymap)))
    (org-catalyst-setup-status-bindings nil map)
    map))

(define-derived-mode org-catalyst-mode
  special-mode "Org Catalyst"
  "Major mode for Catalyst."
  (toggle-truncate-lines 1)
  (setq-local tab-width 4))

;;; Hooks

(add-hook 'before-save-hook
          #'org-catalyst--invalidate-config-cache)

;;; Footer

(provide 'org-catalyst)

;;; org-catalyst.el ends here