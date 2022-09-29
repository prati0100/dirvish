;;; dirvish-subtree.el --- Turn Dirvish into a tree browser -*- lexical-binding: t -*-

;; Copyright (C) 2021-2022 Alex Lu
;; Author : Alex Lu <https://github.com/alexluigit>
;; Version: 2.0.53
;; Keywords: files, convenience
;; Homepage: https://github.com/alexluigit/dirvish
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This extension allows users to insert subdirectories in a tree-like fashion,
;; like `dired-subtree' or `treemacs', but simpler and faster.

;;; Code:

(declare-function all-the-icons-octicon "all-the-icons")
(require 'dirvish)

(defcustom dirvish-subtree-listing-switches nil
  "Listing SWITCHES used in subtrees.
The value may be a string of options or nil which means the
working switches of current buffer will be used."
  :type '(choice symbol string) :group 'dirvish)

(define-obsolete-variable-alias 'dirvish-subtree-line-prefix 'dirvish-subtree-prefix "Sep 1, 2022")
(defcustom dirvish-subtree-prefix " │"
  "A string put into each nested subtree.
The prefix is repeated \"depth\" times."
  :type 'string :group 'dirvish)

(defcustom dirvish-subtree-save-on-revert t
  "Non-nil means `revert-buffer' keeps all expanded subtrees."
  :type 'boolean :group 'dirvish
  :set (lambda (k v)
         (set k v)
         (if v (add-hook 'dirvish-after-revert-hook #'dirvish-subtree--revert)
           (remove-hook 'dirvish-after-revert-hook #'dirvish-subtree--revert))))

(defcustom dirvish-subtree-always-show-state nil
  "Non-nil means always show the subtree state indicator."
  :type 'boolean :group 'dirvish)

(defvar dirvish-subtree--state-icons nil)
(defcustom dirvish-subtree-state-style 'chevron
  "Icon/string used for directory expanded state.
The value can be one of: `plus', `arrow', `chevron'."
  :group 'dirvish :type 'symbol
  :set
  (lambda (k v)
    (and (eq v 'chevron) (not (require 'all-the-icons nil t)) (setq v 'arrow))
    (set k v)
    (setq dirvish-subtree--state-icons
          (pcase (symbol-value k)
            ('plus (cons (propertize "-" 'face 'dirvish-subtree-state)
                         (propertize "+" 'face 'dirvish-subtree-state)))
            ('arrow (cons (propertize "▾" 'face 'dirvish-subtree-state)
                          (propertize "▸" 'face 'dirvish-subtree-state)))
            ('chevron
             (cons
              (all-the-icons-octicon
               "chevron-down"
               :height (* (or (bound-and-true-p dirvish-all-the-icons-height) 1) 0.8)
               :v-adjust 0.1 :face 'dirvish-subtree-state)
              (all-the-icons-octicon
               "chevron-right"
               :height (* (or (bound-and-true-p dirvish-all-the-icons-height) 1) 0.8)
               :v-adjust 0.1 :face 'dirvish-subtree-state)))))))

(defface dirvish-subtree-state
  '((t (:inherit dired-ignored :underline nil :background unspecified)))
  "Face used for `expanded-state' attribute."
  :group 'dirvish)

(defface dirvish-subtree-guide
  '((t (:inherit dired-ignored :underline nil :background unspecified)))
  "Face used for `expanded-state' attribute."
  :group 'dirvish)

(defvar-local dirvish-subtree--overlays nil "Subtree overlays in this buffer.")

(cl-loop
 for (sym ad how) in '((dired-current-directory dirvish-curr-dir-a :around)
                       (dired-subdir-index dirvish-subdir-index-a :around)
                       (dired-get-subdir dirvish-get-subdir-a :around)
                       (dired-remove-entry dirvish-remove-entry-a :around)
                       (dired-create-empty-file dirvish-new-empty-file-a :around)
                       (dired-create-directory dirvish-new-directory-a :after))
 do (advice-add sym how ad))

(defun dirvish-curr-dir-a (fn &optional localp)
  "Advice for FN `dired-current-directory'.
LOCALP is the arg for `dired-current-directory', which see."
  (if-let* ((parent (dirvish-subtree--parent))
            (dir (concat (overlay-get parent 'dired-subtree-name) "/")))
      (if localp (dired-make-relative dir default-directory) dir)
    (funcall fn localp)))

(defun dirvish-get-subdir-a (&rest fn-args)
  "Advice for FN-ARGS `dired-get-subdir'."
  (unless (dirvish-subtree--parent) (apply fn-args)))

(defun dirvish-subdir-index-a (fn dir)
  "Advice for FN `dired-subdir-index'.
Ensure correct DIR when inside of a subtree."
  (save-excursion
    (let ((count 0) ov)
      (while (and (setq ov (dirvish-subtree--parent)) (cl-incf count))
        (goto-char (overlay-start ov))
        (dired-previous-line 1))
      (unless (eq count 0) (setq dir (dired-current-directory))))
    (funcall fn dir)))

(defun dirvish-remove-entry-a (fn file)
  "Advice for FN `dired-remove-entry' FILE."
  (if dirvish-subtree--overlays
      (save-excursion
        (and (dirvish-subtree-expand-to file)
	     (let ((inhibit-read-only t))
	       (delete-region (progn (beginning-of-line) (point))
			      (line-beginning-position 2)))))
    (funcall fn file)))

(defun dirvish-new-empty-file-a (fn file)
  "Create an empty file called FILE.
Same as FN `dired-create-empty-file', but use
`dired-current-directory' as the prompt."
  (interactive (list (read-file-name
                      "Create empty file: " (dired-current-directory))))
  (funcall fn file)
  (when dirvish-subtree--overlays (revert-buffer)))

(defun dirvish-new-directory-a (&rest _)
  "Advice for `dired-create-directory'.
Ensure the entry is inserted to the buffer after directory
creation even the entry is in nested subtree nodes."
  (when dirvish-subtree--overlays (revert-buffer)))

(defun dirvish-subtree-prefix ()
  "Calculate subtree prefix length at point."
  (* (length dirvish-subtree-prefix) (dirvish-subtree--depth)))

(defun dirvish-subtree--depth ()
  "Get subtree depth at point."
  (let ((dps (cl-loop for ov in (overlays-at (point)) collect
                      (or (overlay-get ov 'dired-subtree-depth) 0))))
    (or (and dps (apply #'max dps)) 0)))

(defun dirvish-subtree--expanded-p ()
  "70x Faster version of `dired-subtree--is-expanded-p'."
  (save-excursion (< (dirvish-subtree--depth)
                     (progn (forward-line 1) (dirvish-subtree--depth)))))

(defun dirvish-subtree--parent (&optional p)
  "Get the parent subtree overlay at point P."
  (setq p (or p (point)))
  (cl-loop
   with (pov . max) = (cons nil 0)
   for ov in (overlays-at p)
   for depth = (or (overlay-get ov 'dired-subtree-depth) 0)
   do (when (> depth max) (setq pov ov) (setq max depth))
   finally return pov))

(defun dirvish-subtree--readin (dir)
  "Readin DIR as a subtree node."
  (let ((flags (or dirvish-subtree-listing-switches dired-actual-switches)) str)
    (with-temp-buffer
      (cl-letf (((symbol-function 'dired-insert-set-properties) #'ignore))
        (dired-insert-directory (file-name-as-directory dir) flags)
        (setq str (buffer-string))
        (if (or (= (length str) 0) (string-prefix-p "//DIRED-OPTIONS//" str)) ""
          (substring (buffer-string) 0 -1))))))

(defun dirvish-subtree--insert ()
  "Insert subtree under this directory."
  (let* ((dir (dired-get-filename))
         (listing (dirvish-subtree--readin dir))
         buffer-read-only beg end)
    (dirvish-data-for-dir dir (current-buffer) nil)
    (with-silent-modifications
      (save-excursion
        (setq beg (progn (move-end-of-line 1) (insert "\n") (point)))
        (setq end (progn (insert listing) (1+ (point))))))
    (let* ((ov (make-overlay beg end))
           (parent (dirvish-subtree--parent (1- beg)))
           (p-depth (and parent (1+ (overlay-get parent 'dired-subtree-depth))))
           (depth (or p-depth 1))
           (prefix (apply #'concat (make-list depth dirvish-subtree-prefix))))
      (overlay-put ov 'line-prefix
                   (propertize prefix 'face 'dirvish-subtree-guide))
      (overlay-put ov 'dired-subtree-name dir)
      (overlay-put ov 'dired-subtree-depth depth)
      (overlay-put ov 'evaporate t)
      (push ov dirvish-subtree--overlays))))

(defun dirvish-subtree--revert (&optional clear)
  "Put the `dired-subtree-overlays' again after buffer reverting.
When CLEAR, remove all subtrees in the buffer."
  (cl-loop
   with maps = () with index = (dirvish-prop :old-index)
   for ov in dirvish-subtree--overlays
   for depth = (overlay-get ov 'dired-subtree-depth)
   for name = (overlay-get ov 'dired-subtree-name)
   do (push (cons depth name) maps)
   finally
   (setq dirvish-subtree--overlays nil)
   (if (or clear (bound-and-true-p dirvish-emerge--group-overlays))
       (cl-loop for (depth . name) in maps
                when (dired-goto-file name)
                do (progn (dired-next-line 1) (dirvish-subtree-remove))
                finally (and index (dired-goto-file index)))
     (cl-loop for (depth . name) in maps
              when (and (dirvish-subtree-expand-to name)
                        (not (dirvish-subtree--expanded-p)))
              do (dirvish-subtree--insert)
              finally (and index (dirvish-subtree-expand-to index))))))

(dirvish-define-attribute subtree-state
  "A indicator for directory expanding state."
  :when (or dirvish-subtree-always-show-state dirvish-subtree--overlays)
  :width 1
  (let ((state-str
         (propertize (if (eq (car f-type) 'dir)
                         (if (dirvish-subtree--expanded-p)
                             (car dirvish-subtree--state-icons)
                           (cdr dirvish-subtree--state-icons))
                       " ")))
        (ov (make-overlay (1+ l-beg) (1+ l-beg))))
    (when hl-face
      (add-face-text-property 0 1 hl-face t state-str))
    (overlay-put ov 'after-string state-str)
    `(ov . ,ov)))

(defun dirvish-subtree--move-to-file (file depth)
  "Move to FILE at subtree DEPTH."
  (let (stop f-beg)
    (while (and (not stop)
                (= (forward-line) 0)
                (setq f-beg (dired-move-to-filename)))
      (and (eq depth (dirvish-subtree--depth))
           (equal file (buffer-substring f-beg (dired-move-to-end-of-filename)))
           (setq stop t)))
    stop))

(defun dirvish-subtree-expand-to (target)
  "Go to line describing TARGET and expand its parent directories."
  (interactive
   (list (directory-file-name (expand-file-name
	                       (read-file-name "Expand to file: "
			                       (dired-current-directory))))))
  (let ((file (dired-get-filename nil t)) (dir (dired-current-directory)))
    (cond ((equal file target) target)
          ((and file (string-prefix-p file target))
           (unless (dirvish-subtree--expanded-p) (dirvish-subtree--insert))
           (let ((depth (1+ (dirvish-subtree--depth)))
                 (next (car (split-string
                            (substring target (1+ (length file))) "/"))))
             (when (dirvish-subtree--move-to-file next depth)
               (dirvish-subtree-expand-to target)))
           (dirvish-subtree-expand-to target))
          ((string-prefix-p dir target)
           (let ((depth (dirvish-subtree--depth))
                 (next (car (split-string (substring target (length dir)) "/"))))
             (goto-char (dired-subdir-min))
             (goto-char (next-single-property-change (point) 'dired-filename))
             (forward-line -1)
             ;; TARGET is either not exist or being hidden (#135)
             (when (dirvish-subtree--move-to-file next depth)
               (dirvish-subtree-expand-to target))))
          ((string-prefix-p (expand-file-name default-directory) dir)
           (goto-char (dired-subdir-min))
           (goto-char (next-single-property-change (point) 'dired-filename))
           (dirvish-subtree-expand-to target)))))

;;;###autoload
(defun dirvish-subtree-up ()
  "Jump to beginning of current subtree."
  (interactive)
  (when-let ((ov (dirvish-subtree--parent)))
    (goto-char (overlay-start ov))
    (dired-previous-line 1)))

;;;###autoload
(defun dirvish-subtree-remove ()
  "Remove subtree at point."
  (interactive)
  (when-let* ((ov (dirvish-subtree--parent))
              (beg (overlay-start ov))
              (end (overlay-end ov)))
    (goto-char beg)
    (dired-previous-line 1)
    (cl-loop for o in (overlays-in (point-min) (point-max))
             when (and (overlay-get o 'dired-subtree-depth)
                       (>= (overlay-start o) beg)
                       (<= (overlay-end o) end))
             do (setq dirvish-subtree--overlays
                      (delq o dirvish-subtree--overlays)))
    (with-silent-modifications
      (delete-region (overlay-start ov) (overlay-end ov)))))

;;;###autoload
(defun dirvish-subtree-clear ()
  "Clear all subtrees in the buffer."
  (interactive)
  (dirvish-subtree--revert t)
  (goto-char (point-min)))

(defalias 'dirvish-toggle-subtree #'dirvish-subtree-toggle
  "Insert subtree at point or remove it if it was not present.")
;;;###autoload
(defun dirvish-subtree-toggle ()
  "Insert subtree at point or remove it if it was not present."
  (interactive)
  (if (dirvish-subtree--expanded-p)
      (progn (dired-next-line 1) (dirvish-subtree-remove))
    (dirvish-subtree--insert)))

(defun dirvish-subtree-toggle-or-open (ev)
  "Toggle the subtree if in a dirline, otherwise open the file.
This command takes a mouse event EV as its argment."
  (interactive "e")
  (let ((win (posn-window (event-end ev)))
        (pos (posn-point (event-end ev))))
    (unless (windowp win) (error "No file chosen"))
    (select-window win)
    (with-current-buffer (window-buffer win)
      (goto-char pos)
      (condition-case nil
          (dirvish-subtree-toggle)
        (error (dirvish-find-entry-a (dired-get-file-for-visit)))))
    (when (window-live-p win) (select-window win))))

;;;###autoload (autoload 'dirvish-subtree-menu "dirvish-subtree" nil t)
(transient-define-prefix dirvish-subtree-menu ()
  "Help menu for `dirvish-subtree-*' commands."
  [:description
   (lambda () (dirvish--format-menu-heading "Manage subtrees"))
   ("TAB" "Toggle subtree"             dirvish-subtree-toggle :transient t)
   ("u" "  Move up 1 depth level"      dirvish-subtree-up)
   ("r" "  Remove current subtree"     dirvish-subtree-remove)
   ("c" "  Remove all subtrees"        dirvish-subtree-clear)])

(provide 'dirvish-subtree)
;;; dirvish-subtree.el ends here
