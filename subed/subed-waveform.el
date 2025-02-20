;;; subed-waveform.el --- display waveforms in subed buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2023 Sacha Chua, Marcin Borkowski

;; Author: Sacha Chua <sacha@sachachua.com>, Marcin Borkowski <mbork@mbork.pl>
;; Keywords: multimedia

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This file contains variables, options, functions and commands for
;; displaying a waveform along with the current subtitle.  Use
;; `subed-waveform-minor-mode' to turn the waveform display on or off.
;; Press `C-x C-=' and `C-x C--' to make the amplitude of the
;; displayed waveform larger and smaller.

;; To set the start time, click the waveform with `mouse-1' (left-click).
;; To set the stop time, use `mouse-3' (right-click).
;; You can also adjust start/stop times with the following
;; keybindings from `subed-mode-map':
;; M-[ - `subed-decrease-start-time'
;; M-] - `subed-increase-start-time'
;; M-{ - `subed-decrease-stop-time'
;; M-} - `subed-increase-stop-time'

;; To play a sample from the middle of a waveform, middle-click on the
;; position you would like to play.  This plays
;; `subed-waveform-sample-msecs' milliseconds and then sets the
;; playing position to that point.

;; You can shift-drag with `mouse-1' (left mouse button) to the left
;; of a subtitle's waveform in order to extend the view earlier and
;; set the start time. `Shift-drag-mouse-3' (right mouse button) to
;; extend the view later and set the stop time.

;; To split a subtitle in the middle using the text at point, use
;; S-C-mouse-2 (control-shift middle-click), which is bound to
;; `subed-waveform-split'.

;; Customization:

;; Use `M-x customize-group subed-waveform' to configure options.  To
;; change how much time you see before or after the current subtitle,
;; set `subed-waveform-preview-msecs-before' and
;; `subed-waveform-preview-msecs-after'. You may also want to adjust
;; `subed-loop-seconds-before' and `subed-loop-seconds-after' if you
;; want this to match the looping behavior toggled with
;; `subed-toggle-loop-over-current-subtitle'. (Note the switch from
;; milliseconds to seconds.)  The boundaries of the current subtitle
;; as well as the current playing position are indicated with the
;; colors set in `subed-waveform-bar-params'.
;;
;; To change how your adjustments affect previous/next subtitles,
;; customize the `subed-enforce-time-boundaries' and
;; `subed-subtitle-spacing' variables.

;; To automatically display subtitles whenever you open a subed file,
;; add the following to your configuration:
;;
;; (with-eval-after-load 'subed
;;   (add-hook 'subed-mode-hook 'subed-waveform-minor-mode))
;;
;; Troubleshooting:

;; If the waveform becomes corrupted or is out of sync (this may
;; happen for example when you modify the start/stop timestamp(s)
;; using Subed mode commands but then undo your changes), press `C-c
;; |' to redisplay it.

;; If images are not displayed, you may want to make sure that
;; `max-image-size' is set to a value that allows short, wide images.
;; The following code may help:
;;
;; (with-eval-after-load 'subed
;;   (add-hook 'subed-mode-hook (lambda () (setq-local max-image-size nil))))
;;

;;; Code:

(defgroup subed-waveform nil
  "Minor mode for viewing subtitle waveforms while in `subed-mode'."
  :group 'subed
  :prefix "subed-waveform")

(defcustom subed-waveform-ffmpeg-executable "ffmpeg"
  "Path to the FFMPEG executable used for generating waveforms."
  :type 'file
  :group 'subed-waveform)

(defcustom subed-waveform-ffmpeg-filter-args ":colors=gray"
  "Additional arguments for the showwavespic filter.
The background is black by default and the foreground gray.
To change the foreground color, use something like
\":colors=white\".  To invert the colors (for example to obtain
black on white), use \":colors=white,negate\".

You can also set it to a function.  The function will be called
with WIDTH and HEIGHT as parameters, and should return a string
to include in the filter.  See `subed-waveform-fancy-filter' for
an example."
  :type '(choice
          (string :tag "Extra arguments to include")
          (function :tag "Function to call with the width and height"))
  :group 'subed-waveform)

(defcustom subed-waveform-bar-params
  '((:start . (:id "start" :stroke-color "darkgreen" :stroke-width "3"))
    (:stop . (:id "stop" :stroke-color "darkred" :stroke-width "3"))
    (:current . (:id "current" :stroke-color "orange" :stroke-width "2")))
  "An alist of bar types and parameters.
The keys in it are `:start', `:stop' and `:current'.  The values are
SVG parameters of the displayed bars.  Every bar must have a unique
`:id' parameter."
  :type '(alist :key-type (choice (const :tag "Start" :start)
          (const :tag "Stop" :stop)
          (const :tag "Current" :current))
    :value-type (plist :key-type symbol :value-type string))
  :group 'subed-waveform)

(defcustom subed-waveform-preview-msecs-before 2000
  "Prelude in milliseconds displaying subtitle waveform."
  :type 'integer
  :group 'subed-waveform)

(defcustom subed-waveform-preview-msecs-after 2000
  "Addendum in seconds when displaying subtitle waveform."
  :type 'integer
  :group 'subed-waveform)

(defcustom subed-waveform-sample-msecs 2000
  "Number of milliseconds to play when jumping around a waveform.
0 or nil means don't play a sample."
  :type 'integer
  :group 'subed-waveform)

(defcustom subed-waveform-volume
  2.0
  "A multiplier of the volume.
Set it to more than 1.0 if the voice is too quiet and the moments
when people speak are indistinguishable from silence."
  :type 'number
  :group 'subed-waveform)

(defcustom subed-waveform-timestamp-resolution
  20
  "Resolution of the timestamps.
When the user clicks on the waveform, the timestamp set will be
rounded to the nearest multiple of this number."
  :type 'integer
  :group 'subed-waveform)

(defun subed-waveform-remove ()
  "Remove waveform overlay."
  (interactive)
  (remove-overlays (point-min) (point-max) 'subed-waveform t)
  (when (overlayp subed-waveform--image-overlay)
    (delete-overlay subed-waveform--image-overlay)))

(defvar subed-waveform-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-=") #'subed-waveform-volume-increase)
    (define-key map (kbd "C-c C--") #'subed-waveform-volume-decrease)
    (define-key map (kbd "C-c |") #'subed-waveform-put-svg)
    map)
  "Keymap for `subed-waveform-minor-mode'.")

;;;###autoload
(define-minor-mode subed-waveform-minor-mode
  "Display waveforms for subtitles. Update on motion."
  :keymap subed-waveform-minor-mode-map
	:lighter "w"
	:require 'subed
  (if subed-waveform-minor-mode
      (progn
        (add-hook 'before-save-hook #'subed-waveform-remove nil t)
        (add-hook 'after-save-hook #'subed-waveform-put-svg nil t)
        (add-hook 'subed-subtitle-motion-hook #'subed-waveform-put-svg nil t)
        (add-hook 'after-change-motion-hook #'subed-waveform-put-svg nil t)
        (add-hook 'subed-mpv-playback-position-hook #'subed-waveform--update-current-bar t)
        (add-hook 'subed-subtitle-time-adjusted-hook #'subed-waveform-put-svg nil t)
        (subed-waveform-put-svg))
    (subed-waveform-remove)
    (remove-hook 'before-save-hook #'subed-waveform-remove t)
    (remove-hook 'after-save-hook #'subed-waveform-put-svg t)
    (remove-hook 'subed-subtitle-motion-hook #'subed-waveform-put-svg t)
    (remove-hook 'subed-subtitle-time-adjusted-hook #'subed-waveform-put-svg t)
    (remove-hook 'subed-mpv-playback-position-hook #'subed-waveform--update-current-bar t)
    (remove-hook 'after-change-motion-hook #'subed-waveform-put-svg t)))

(defconst subed-waveform-volume-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-=") #'subed-waveform-volume-increase)
    (define-key map (kbd "C--") #'subed-waveform-volume-decrease)
    map)
  "A keymap for manipulating waveform \"volume\".")

(defun subed-waveform-volume-increase (amount)
  "Increase `subed-waveform-value' by AMOUNT/2."
  (interactive "p")
  (setq subed-waveform-volume (+ subed-waveform-volume (/ amount 2.0)))
  (message "Waveform volume multiplier is now set to %s" subed-waveform-volume)
  (subed-waveform-put-svg)
  (set-transient-map subed-waveform-volume-map))

(defun subed-waveform-volume-decrease (amount)
  "Increase `subed-waveform-value' by AMOUNT/2."
  (interactive "p")
  (setq subed-waveform-volume (max 1.0
           (- subed-waveform-volume (/ amount 2.0))))
  (message "Waveform volume multiplier is now set to %s" subed-waveform-volume)
  (subed-waveform-put-svg)
  (set-transient-map subed-waveform-volume-map))

(defun subed-waveform-fancy-filter (width height)
  "Display green waveforms on a dark green background with a grid.
WIDTH and HEIGHT are given in pixels."
  (concat
   ":colors=#9cf42f[fg];"
   (format "color=s=%dx%d:color=#44582c,drawgrid=width=iw/10:height=ih/5:color=#9cf42f@0.1[bg];"
           width height)
   "[bg][fg]overlay=format=auto,drawbox=x=(iw-w)/2:y=(ih-h)/2:w=iw:h=1:color=#9cf42f"))

(defun subed-waveform--from-file (filename from to width height)
  "Returns a string representing the image data in PNG format.
FILENAME is the input file, FROM and TO are time positions, WIDTH
and HEIGHT are dimensions in pixels."
  (let* ((args
          (append
           (list "-accurate_seek"
                 "-ss" (format "%s" from)
                 "-to" (format "%s" to))
           (list "-i" filename)
           (list
            "-loglevel"
            "0"
            "-filter_complex"
            (format "volume=%s,showwavespic=s=%dx%d%s"
                    subed-waveform-volume
                    width height
                    (cond
                     ((functionp subed-waveform-ffmpeg-filter-args)
                      (funcall subed-waveform-ffmpeg-filter-args width height))
                     ((stringp subed-waveform-ffmpeg-filter-args)
                      subed-waveform-ffmpeg-filter-args)
                     (t "")))
            "-frames:v" "1"
            "-c:v" "png"
            "-f" "image2" "-"))))
    (with-temp-buffer
      (apply 'call-process subed-waveform-ffmpeg-executable nil t nil args)
      (encode-coding-string (buffer-string) 'binary))))

(defvar-local subed-waveform--start nil
  "Timestamp (in milliseconds) of the start of the waveform.")
(defvar-local subed-waveform--stop nil
  "Timestamp (in milliseconds) of the stop of the waveform.")
(defvar-local subed-waveform--pixels-per-second nil
  "Number of pixels used for displaying one second.")

(defun subed-waveform--msecs-to-ffmpeg (msecs)
  "Convert MSECS to string in the format HH:MM:SS.MS."
  (concat (format-seconds "%02h:%02m:%02s" (/ (floor msecs) 1000))
          "." (format "%03d" (mod (floor msecs) 1000))))

(defun subed-waveform--position-to-percent (pos start stop)
  "Return a percentage of POS relative to START/STOP."
  (when pos
    (format "%s%%" (/ (* 100 (- pos start)) (- stop start)))))

(defvar-local subed-waveform--pos nil
  "Buffer position of the image with the current waveform.")

(defvar-local subed-waveform--svg nil
  "SVG image with the current waveform.")

(defvar-local subed-waveform--image-overlay nil
  "The overlay with the waveform.")

;; TODO: determine height/width only once
(defun subed-waveform--set-svg ()
  "Create the svg for the waveform of the current subtitle.
Set `subed-waveform--svg' and `subed-waveform--pos'."
  (save-excursion
    (let ((start (subed-subtitle-msecs-start))
          (stop (subed-subtitle-msecs-stop)))
      (setq subed-waveform--start
            (floor (max 0 (- start subed-waveform-preview-msecs-before))))
      (setq subed-waveform--stop
            (floor (+ stop subed-waveform-preview-msecs-after)))
      (when (> subed-waveform--stop subed-waveform--start)
        (let* ((width (string-pixel-width (make-string fill-column ?*)))
               (height (save-excursion
                         ;; don't count the current waveform towards the
                         ;; line height
                         (forward-line -1)
                         (* 2 (line-pixel-height))))
               (image (subed-waveform--from-file
                       (or subed-mpv-media-file (error "No media file found"))
                       (subed-waveform--msecs-to-ffmpeg subed-waveform--start)
                       (subed-waveform--msecs-to-ffmpeg subed-waveform--stop)
                       width
                       height)))
          (setq subed-waveform--pixels-per-second (/ width (* 0.001 (- stop start))))
          (setq subed-waveform--svg (svg-create width height))
          (svg-embed subed-waveform--svg image "image/png" t
                     :x 0 :y 0
                     :width "100%" :height "100%"
                     :preserveAspectRatio "none")
          (subed-waveform--update-bars (subed-subtitle-msecs-start)))))))

(defun subed-waveform--move-bar (bar-type position)
  "Update `subed-waveform--svg', moving bar BAR-TYPE to POSITION.
BAR-TYPE should be a symbol, one of :start, :stop, :current.
POSITION should be a percentage as a string."
  (svg-remove subed-waveform--svg
        (plist-get (alist-get bar-type subed-waveform-bar-params)
                   ":id"
                   #'string=))
  (apply #'svg-line
   subed-waveform--svg position 0 position "100%"
   (alist-get bar-type subed-waveform-bar-params)))

(defun subed-waveform--update-bars (subed-subtitle-msecs-start)
  "Update the bars in `subed-waveform--svg'.
Recompute the waveform if the start bar is too far to the left or
the stop bar is too far to the right."
  (let* ((start subed-subtitle-msecs-start)
   (stop (subed-subtitle-msecs-stop))
   (start-pos (subed-waveform--position-to-percent
         start
         subed-waveform--start
         subed-waveform--stop))
   (stop-pos (subed-waveform--position-to-percent
        stop
        subed-waveform--start
        subed-waveform--stop)))
    (when (or (not subed-waveform--svg)
        (< start subed-waveform--start)
        (> stop subed-waveform--stop))
      (subed-waveform--set-svg))
    (subed-waveform--move-bar :start start-pos)
    (subed-waveform--move-bar :stop stop-pos))
  (subed-waveform--update-current-bar subed-mpv-playback-position))

(defun subed-waveform--update-current-bar (subed-mpv-playback-position)
  "Update the \"current\" bar in `subed-waveform--svg'.
Assume all necessary variables are already set.  This function is
meant to be as fast as possible so that it can be called many
times per second."
  (when subed-mpv-playback-position
    (subed-waveform--move-bar
     :current
     (subed-waveform--position-to-percent
      subed-mpv-playback-position
      subed-waveform--start
      subed-waveform--stop)))
  (subed-waveform--update-overlay-svg))

(defvar subed-waveform-svg-map
  (let ((subed-waveform-svg-map (make-keymap)))
    (define-key subed-waveform-svg-map [mouse-1] #'subed-waveform-set-start)
    (define-key subed-waveform-svg-map [mouse-2] #'subed-waveform-jump-to-timestamp)
    (define-key subed-waveform-svg-map [mouse-3] #'subed-waveform-set-stop)
    (define-key subed-waveform-svg-map [down-mouse-3] #'ignore)
    (define-key subed-waveform-svg-map [C-mouse-2] #'ignore)
    (define-key subed-waveform-svg-map [S-mouse-3] #'ignore)
    (define-key subed-waveform-svg-map [C-mouse-3] #'ignore)
    (define-key subed-waveform-svg-map [S-down-mouse-1] #'ignore)
    (define-key subed-waveform-svg-map [S-drag-mouse-1] #'subed-waveform-reduce-start-time)
    (define-key subed-waveform-svg-map [S-down-mouse-3] #'ignore)
    (define-key subed-waveform-svg-map [S-drag-mouse-3] #'subed-waveform-increase-stop-time)
    (define-key subed-waveform-svg-map [S-C-down-mouse-2] #'subed-waveform-split)
    (define-key subed-waveform-svg-map [S-mouse-1] #'ignore)
    (define-key subed-waveform-svg-map [C-mouse-1] #'ignore)
    subed-waveform-svg-map)
  "A keymap for clicking on the waveform.")

(defun subed-waveform--update-overlay-svg ()
  "Update the SVG in the overlay.
Assume `subed-waveform--svg' is already set."
  (overlay-put subed-waveform--image-overlay
         'before-string
         (propertize
          " "
          'display (svg-image subed-waveform--svg)
          'pointer 'arrow
          'keymap subed-waveform-svg-map)))

(defun subed-waveform-put-svg (&rest _)
  "Put an overlay with the SVG in the current subtitle.
Set the relevant variables if necessary.
This function ignores arguments and can be used in hooks."
  (interactive)
  (setq subed-waveform--pos (subed-jump-to-subtitle-text))
  (when subed-waveform--pos
    (if (overlayp subed-waveform--image-overlay)
        (move-overlay subed-waveform--image-overlay
                      subed-waveform--pos subed-waveform--pos)
      (setq subed-waveform--image-overlay
            (make-overlay subed-waveform--pos subed-waveform--pos))
      (overlay-put subed-waveform--image-overlay 'subed-waveform t)
      (overlay-put subed-waveform--image-overlay
                   'after-string
                   "\n"))
    (subed-waveform--set-svg)))

;;; Adjusting based on the mouse

(defun subed-waveform--mouse-event-to-ms (event)
  "Return the millisecond position of EVENT."
  (let* ((x (car (elt (cadr event) 8)))
         (width (car (elt (cadr event) 9))))
    (* subed-waveform-timestamp-resolution
       (round (+ (* (/ (* 1.0 x) width)
                    (- subed-waveform--stop subed-waveform--start))
                 subed-waveform--start)
              subed-waveform-timestamp-resolution))))

(defun subed-waveform-set-start (event)
  "Set the start timestamp in the place clicked."
  (interactive "e")
  (subed-set-subtitle-time-start (subed-waveform--mouse-event-to-ms event))
  (subed-waveform--update-bars (subed-subtitle-msecs-start)))

(defun subed-waveform-set-stop (event)
  "Set the start timestamp in the place clicked."
  (interactive "e")
  (subed-set-subtitle-time-stop (subed-waveform--mouse-event-to-ms event))
  (subed-waveform--update-bars (subed-subtitle-msecs-start)))

(defun subed-waveform-reduce-start-time (event)
  "Make this subtitle start `subed-milliseconds-adjust' milliseconds earlier."
  (interactive "e")
  (save-excursion
    (when subed-waveform--pixels-per-second
      (let* ((x1 (car (elt (elt event 2) 2)))
             (x2 (car (elt (elt event 1) 2)))
             (msecs
              (floor (* 1000 (/ (- x1 x2) ; pixels moved
                                subed-waveform--pixels-per-second)))))
        (subed-adjust-subtitle-time-start msecs)))))

(defun subed-waveform-increase-stop-time (event)
  "Make this subtitle stop later.
If called from a mouse drag EVENT, adjust it proportionally to
what is displayed.  If not, adjust it
by `subed-milliseconds-adjust' milliseconds."
  (interactive "e")
  (save-excursion
    (when subed-waveform--pixels-per-second
      (let* ((x1 (car (elt (elt event 2) 2)))
             (x2 (car (elt (elt event 1) 2)))
             (msecs
              (floor (* 1000 (/ (- x1 x2) ; pixels moved
                                subed-waveform--pixels-per-second)))))
        (subed-adjust-subtitle-time-stop msecs)))))

(defun subed-waveform-split (event)
  "Split the current subtitle.
Use the selected timestamp as the start time of the next subtitle, leaving a gap of
`subed-subtitle-spacing'."
  (interactive "e")
  (save-excursion
    (let ((ms (subed-waveform--mouse-event-to-ms event)))
      (subed-split-subtitle (- ms (subed-subtitle-msecs-start))))))

;;; Sampling

(defvar-local subed-waveform--sample-timer nil "Timer used for sampling.
Resets MPV position when done.")

(defun subed-waveform-jump-to-timestamp (event)
  "Jump to the timestamp at EVENT and play a short sample.
The `subed-waveform-sample-msecs' variable specifies the duration
of the sample.  Jump to the specified position afterwards so that
you can use it in `subed-split-subtitle' and other commands."
  (interactive "e")
  (let* ((ms (subed-waveform--mouse-event-to-ms event))
         (ts (subed-msecs-to-timestamp ms)))
    (subed-mpv-jump ms)
    (message "%s" ts)
    (if (> (or subed-waveform-sample-msecs 0) 0)
        (subed-waveform-play-sample
         ms
         (min
          (- subed-waveform--stop ms)
          subed-waveform-sample-msecs))
      (subed-mpv-jump ms))))

(defun subed-waveform--restore-mpv-position (reset-msecs)
  "Jump back to RESET-MSECS."
  (subed-mpv-pause)
  (subed-mpv-jump reset-msecs)
  (when subed-waveform--enable-point-to-player-sync-after-sample
    (subed-enable-sync-point-to-player t))
  (when subed-waveform--enable-loop-over-current-subtitle-after-sample
    (subed-enable-loop-over-current-subtitle t))
  (setq subed-waveform--enable-loop-over-current-subtitle-after-sample nil
        subed-waveform--enable-point-to-player-sync-after-sample nil))

(defun subed-waveform-play-sample (msecs &optional duration-ms)
  "Play starting at MSECS position for DURATION-MS seconds.
If DURATION is unspecified, use `subed-waveform-sample-msecs.'"
  (subed-mpv-jump msecs)
  (subed-mpv-unpause)
  (when (subed-loop-over-current-subtitle-p)
    (setq subed-waveform--enable-loop-over-current-subtitle-after-sample t)
    (subed-disable-loop-over-current-subtitle t))
  (when (subed-sync-point-to-player-p)
    (setq subed-waveform--enable-point-to-player-sync-after-sample t)
    (subed-disable-sync-point-to-player t))
  (if (timerp subed-waveform--sample-timer) (cancel-timer subed-waveform--sample-timer))
  (setq subed-waveform--sample-timer
        (run-at-time (/ (or duration-ms subed-waveform-sample-msecs) 1000.0) nil
                     #'subed-waveform--restore-mpv-position
                     msecs)))


(provide 'subed-waveform)
;;; subed-waveform.el ends here
