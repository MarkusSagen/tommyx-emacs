
;; pre-load configurations
(setq org-directory "~/notes/org") ; remove this if you are not me.
(setq use-light-theme nil) ; set to t if you want to startup with light theme.

(load "~/tommyx-emacs/tommyx.el")

;; post-load configurations
; add things to org agenda files
(setq org-agenda-files (append org-agenda-files '()))

; emms
(setq mpg123-path "D:/data/projects/new/Tools/tommyx-emacs/third_party/mpg123/mpg123.exe")
