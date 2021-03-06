(in-package :c)

(s::emit "#LoROM")

(proto set_background_color)

(proc (main int) ()

  "Set screen to max brightness"
  (s::8-bit-mode)
  (s::asm s::lda :immediate #x0F)
  (s::asm s::sta :absolute #x2100)
  (s::16-bit-mode)

  (var color int 0)
  (while (s::lda 1)

    "Get input from the controller"
    (s::asm s::lda :absolute #x4218)
    (if (s::asm s::and :immediate-w #x0100) ;; is right button depressed?
       (++ color)
       color)
    (set_background_color color #x0000)))

(proc (set_background_color void) (color color_address)
  color_address
  (s::8-bit-mode)
  (s::asm s::sta :absolute #x2121)
  (s::16-bit-mode)

  color
  (s::8-bit-mode)
  (s::asm s::sta :absolute #x2122)
  (s::asm s::xba :implied)
  (s::asm s::sta :absolute #x2122)
  (s::16-bit-mode))
