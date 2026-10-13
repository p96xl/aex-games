/* PONG + instrumentation, all-in-one (hook 0x80014AE4, direct USART1 draw). Unit stays a playable
 * Pong AND a bench rig: it enables touch, logs USART1 RX (touch events) to SRAM, and snapshots the
 * ADC region each frame. Read over JTAG (jtag_runtest) after a normal boot:
 *   0xF000      frame counter (liveness)
 *   0xF0F0      RX byte count ; 0xF100.. up to 240 RX bytes (touch events -> format + proof panel is
 *               live/bidirectional; the stalled "screen feedback reader", answered by a finger tap)
 *   0xF200..    32 words from ADCIFA 0xFFFF4800 (handswitch: hold CUT/COAG at bench, see which changes)
 * Control is still AI; once we see the touch-event format and the ADC bands we wire them into r0.
 * state r0=lpy r1=rpy r2=bx r3=by r4=vx r5=vy r6=ls r7=rs. No csrf (our polled TX/RX owns USART1).
 */
	.text
	.global	game_entry
game_entry:
	mov	r8, 0xF000		/* frame counter = 0 */
	mov	r9, 0
	st.w	r8[0], r9
	mov	r8, 0xF0F0		/* rx count = 0 */
	mov	r9, 0
	st.w	r8[0], r9
	mov	r8, 0xF0F4		/* left-paddle touch target = 195 (mid) */
	mov	r9, 195
	st.w	r8[0], r9
	mov	r8, 0xF0F8		/* touch parse state = 0 (idle) */
	mov	r9, 0
	st.w	r8[0], r9
	mov	r8, 0xF0D0		/* last-drawn score = -1 so 0:0 draws once */
	mov	r9, -1
	st.w	r8[0], r9
	mov	r8, 0xF0D4
	st.w	r8[0], r9
	mov	r9, 0
	mov	r8, 0xF0E4		/* handpiece debounce: last class = 0 */
	st.w	r8[0], r9
	mov	r8, 0xF0E8		/* handpiece debounce: stable count = 0 */
	st.w	r8[0], r9
	mov	r8, 0xF0D8		/* NEM red-flash timer = 0 */
	st.w	r8[0], r9
	mov	r8, 0xF0DC		/* last AI score = 0 */
	st.w	r8[0], r9
	rcall	led_init		/* NEM LED pins 95/106 as outputs */
	rcall	led_green		/* glow green = in play */
	rcall	scrinit			/* clear + title (cold-boot panel may miss this; loop re-sends) */
	mov	r0, 195
	mov	r1, 195
	mov	r2, 400
	mov	r3, 240
	mov	r4, 10
	mov	r5, 6
	mov	r6, 0
	mov	r7, 0
	rcall	drawall			/* initial full scene + seed last-drawn trackers */
.loop:
	mov	r8, 0xF000
	ld.w	r9, r8[0]
	sub	r9, -1
	st.w	r8[0], r9
	/* cold boot: panel may lag. Re-send setup every 32 frames for the first ~96 (~5s) only,
	   then STOP -- repeating it longer flickers the screen and cancels in-progress touches. */
	mov	r8, 96
	cp.w	r9, r8
	brgt	.ninit
	bfextu	r8, r9, 0, 5		/* r8 = frame & 31 */
	cp.w	r8, 0
	brne	.ninit
	rcall	scrinit
	rcall	drawall			/* redraw scene after the clear */
	mov	r8, 0xF0D0		/* force score redraw too */
	mov	r9, -1
	st.w	r8[0], r9
	mov	r8, 0xF0D4
	st.w	r8[0], r9
.ninit:
	rcall	rxpoll			/* log touch/RX bytes */
	rcall	hpoll			/* re-sample SPI ADC + classify handpiece -> paddle */
	rcall	hswitch			/* log full ADC buffer + GPIO (diagnosis) */
	/* left paddle follows the handpiece target @0xF0F4 (draw is differential, below) */
	mov	r8, 0xF0F4
	ld.w	r0, r8[0]
	/* right paddle AI */
	mov	r8, r3
	sub	r8, -7
	mov	r9, r1
	sub	r9, -45
	sub	r8, r9			/* ball_y - paddle_center */
	cp.w	r8, 20
	brgt	.rp_dn			/* ball well below center -> move down */
	mov	r9, -20
	cp.w	r8, r9
	brlt	.rp_up			/* ball well above center -> move up */
	rjmp	.rp_cl			/* within deadband -> hold still (no redraw = no flicker) */
.rp_dn:
	sub	r1, -6
	rjmp	.rp_cl
.rp_up:
	sub	r1, 6
.rp_cl:
	cp.w	r1, 0
	brge	.rp_c1
	mov	r1, 0
.rp_c1:
	mov	r8, 390
	cp.w	r1, r8
	brle	.rp_c2
	mov	r1, 390
.rp_c2:
	/* ball */
	add	r2, r4
	add	r3, r5
	cp.w	r3, 80			/* top wall at y=80: reserve 0-80 for title+score (ball can't eat them) */
	brge	.by1
	mov	r3, 80
	neg	r5
.by1:
	mov	r8, 466
	cp.w	r3, r8
	brle	.by2
	mov	r3, 466
	neg	r5
.by2:
	cp.w	r4, 0
	brge	.lcd
	mov	r8, 38
	cp.w	r2, r8
	brgt	.lcd
	mov	r8, r3
	sub	r8, -14
	cp.w	r8, r0
	brlt	.lcd
	mov	r8, r0
	sub	r8, -90
	cp.w	r3, r8
	brgt	.lcd
	neg	r4
	mov	r2, 38
.lcd:
	cp.w	r4, 0
	brle	.rcd
	mov	r8, r2
	sub	r8, -14
	mov	r9, 762
	cp.w	r8, r9
	brlt	.rcd
	mov	r8, r3
	sub	r8, -14
	cp.w	r8, r1
	brlt	.rcd
	mov	r8, r1
	sub	r8, -90
	cp.w	r3, r8
	brgt	.rcd
	neg	r4
	mov	r2, 748
.rcd:
	mov	r8, -14
	cp.w	r2, r8
	brge	.sr1
	sub	r7, -1
	mov	r2, 400
	mov	r3, 240
	mov	r4, 10
.sr1:
	mov	r8, 800
	cp.w	r2, r8
	brle	.sr2
	sub	r6, -1
	mov	r2, 400
	mov	r3, 240
	mov	r4, -10
.sr2:
	/* differential draw: erase+redraw an object only when it moved (no per-frame strobe) */
	mov	r8, 0xF0C0		/* left paddle, last pos @0xF0C0 */
	ld.w	r9, r8[0]
	cp.w	r9, r0
	breq	.d_rp
	mov	r12, 24
	mov	r11, r9			/* erase old */
	mov	r10, 14
	mov	r9, 90
	lda.w	r8, c_blk
	rcall	rect
	mov	r12, 24
	mov	r11, r0			/* draw new */
	mov	r10, 14
	mov	r9, 90
	lda.w	r8, c_wht
	rcall	rect
	mov	r8, 0xF0C0
	st.w	r8[0], r0
.d_rp:
	mov	r8, 0xF0C4		/* right paddle, last pos @0xF0C4 */
	ld.w	r9, r8[0]
	cp.w	r9, r1
	breq	.d_ball
	mov	r12, 762
	mov	r11, r9
	mov	r10, 14
	mov	r9, 90
	lda.w	r8, c_blk
	rcall	rect
	mov	r12, 762
	mov	r11, r1
	mov	r10, 14
	mov	r9, 90
	lda.w	r8, c_wht
	rcall	rect
	mov	r8, 0xF0C4
	st.w	r8[0], r1
.d_ball:
	mov	r8, 0xF0C8		/* ball, last x@0xF0C8 y@0xF0CC (moves every frame) */
	ld.w	r9, r8[0]
	cp.w	r9, r2
	brne	.d_bm
	mov	r8, 0xF0CC
	ld.w	r9, r8[0]
	cp.w	r9, r3
	breq	.d_sc
.d_bm:
	mov	r8, 0xF0C8
	ld.w	r12, r8[0]		/* erase old ball */
	mov	r8, 0xF0CC
	ld.w	r11, r8[0]
	mov	r10, 14
	mov	r9, 14
	lda.w	r8, c_blk
	rcall	rect
	mov	r12, r2			/* draw new ball */
	mov	r11, r3
	mov	r10, 14
	mov	r9, 14
	lda.w	r8, c_grn
	rcall	rect
	mov	r8, 0xF0C8
	st.w	r8[0], r2
	mov	r8, 0xF0CC
	st.w	r8[0], r3
.d_sc:
	/* redraw score only when it changes (was repainting text every frame -> flicker) */
	mov	r8, 0xF0D0
	ld.w	r9, r8[0]
	cp.w	r9, r6
	brne	.scdraw
	mov	r8, 0xF0D4
	ld.w	r9, r8[0]
	cp.w	r9, r7
	breq	.scdone
.scdraw:
	mov	r8, 0xF0D0
	st.w	r8[0], r6
	mov	r8, 0xF0D4
	st.w	r8[0], r7
	mov	r12, r6
	mov	r11, r7
	rcall	score
.scdone:
	rcall	nemled			/* NEM port LED: green in play, red flash on a loss */
	mov	r8, 300000
.dl:
	sub	r8, 1
	cp.w	r8, 0
	brne	.dl
	rjmp	.loop

/* drawall: draw all three objects at current positions and seed the last-drawn trackers. Used at
   startup and after each re-init clear, so a cold-boot panel that missed the first draw, and every
   screen clear, both end with a full scene. Preserves r0-r7 (rect saves them). */
drawall:
	pushm	lr
	mov	r12, 24
	mov	r11, r0
	mov	r10, 14
	mov	r9, 90
	lda.w	r8, c_wht
	rcall	rect
	mov	r8, 0xF0C0
	st.w	r8[0], r0
	mov	r12, 762
	mov	r11, r1
	mov	r10, 14
	mov	r9, 90
	lda.w	r8, c_wht
	rcall	rect
	mov	r8, 0xF0C4
	st.w	r8[0], r1
	mov	r12, r2
	mov	r11, r3
	mov	r10, 14
	mov	r9, 14
	lda.w	r8, c_grn
	rcall	rect
	mov	r8, 0xF0C8
	st.w	r8[0], r2
	mov	r8, 0xF0CC
	st.w	r8[0], r3
	popm	pc

/* rxpoll: drain USART1 RX, append bytes to log @0xF100 (cap 240), count @0xF0F0. preserves r0-r7 */
rxpoll:
	pushm	lr
	mov	r10, 0xF0F0
	ld.w	r11, r10[0]
.rp1:
	movh	r8, 0xFFFF
	orl	r8, 0x2C00
	ld.w	r9, r8[0x14]
	bfextu	r9, r9, 0, 1
	cp.w	r9, 0
	breq	.rp_d
	ld.w	r9, r8[0x18]
	bfextu	r9, r9, 0, 8		/* r9 = received byte */
	/* parse touch report "x<id>\r" -> paddle target @0xF0F4. scratch r8,r12 only (keep r0-r7,r9-r11) */
	cp.w	r9, 0x78		/* 'x' begins a report */
	brne	.pk_dig
	mov	r8, 0xF0F8
	mov	r12, 1
	st.w	r8[0], r12		/* state = collecting */
	mov	r8, 0xF0FC
	mov	r12, 0
	st.w	r8[0], r12		/* id accumulator = 0 */
	rjmp	.pk_done
.pk_dig:
	mov	r8, 0xF0F8
	ld.w	r12, r8[0]
	cp.w	r12, 0
	breq	.pk_done		/* not inside a report */
	cp.w	r9, 0x30
	brlt	.pk_fin
	cp.w	r9, 0x39
	brgt	.pk_fin
	mov	r8, 0xF0FC		/* digit: id = id*10 + (byte-'0') */
	ld.w	r12, r8[0]
	mov	r8, r12
	lsl	r12, 3			/* id*8 */
	lsl	r8, 1			/* id*2 */
	add	r12, r8			/* id*10 */
	mov	r8, r9
	sub	r8, 0x30
	add	r12, r8
	mov	r8, 0xF0FC
	st.w	r8[0], r12
	rjmp	.pk_done
.pk_fin:
	mov	r8, 0xF0F8		/* terminator: close report, state = idle */
	mov	r12, 0
	st.w	r8[0], r12
	mov	r8, 0xF0FC
	ld.w	r12, r8[0]		/* r12 = completed id */
	cp.w	r12, 90
	brne	.pk_f91
	mov	r8, 0xF0F4		/* zone 90 -> up: target -= 80, clamp >=0 */
	ld.w	r12, r8[0]
	sub	r12, 80
	cp.w	r12, 0
	brge	.pk_u
	mov	r12, 0
.pk_u:
	mov	r8, 0xF0F4
	st.w	r8[0], r12
	rjmp	.pk_done
.pk_f91:
	cp.w	r12, 91
	brne	.pk_done
	mov	r8, 0xF0F4		/* zone 91 -> down: target += 80, clamp <=390 */
	ld.w	r12, r8[0]
	sub	r12, -80
	mov	r8, 390
	cp.w	r12, r8
	brle	.pk_d
	mov	r12, 390
.pk_d:
	mov	r8, 0xF0F4
	st.w	r8[0], r12
.pk_done:
	cp.w	r9, 0x0D		/* ignore CR acks in the log */
	breq	.rp1
	cp.w	r9, 0x0A		/* ignore LF */
	breq	.rp1
	cp.w	r11, 240
	brge	.rp1
	mov	r8, 0xF100
	add	r8, r11
	st.b	r8[0], r9
	sub	r11, -1
	rjmp	.rp1
.rp_d:
	st.w	r10[0], r11
	popm	pc

/* hswitch: probe handswitch candidates each frame (preserves r0-r7). 0x800136C8 is the firmware's
   own reader: returns *(0x12D8) if nonzero, else the hardware sense reg *(0xFFFF0C04). Log 4 so the
   bench CUT/COAG press reveals which one tracks:
     0xF0E0 = 0x800136C8() return    0xF0E4 = raw 0xFFFF0C04
     0xF0E8 = firmware-stored 0x1952 (16b)    0xF0EC = override 0x12D8 */
hswitch:
	pushm	lr
	mov	r8, 0x29C4		/* live raw ADC DMA buffer -> 0xF200 (16 halfwords) */
	mov	r9, 0xF200
	mov	r10, 16
.hs_a:
	ld.uh	r11, r8++
	st.h	r9++, r11
	sub	r10, 1
	cp.w	r10, 0
	brne	.hs_a
	movh	r8, 0xFFFF		/* live GPIO PVRs (internal pulls active while app runs) */
	orl	r8, 0x2060
	ld.w	r9, r8[0]
	mov	r8, 0xF240
	st.w	r8[0], r9		/* port A @0xF240 */
	movh	r8, 0xFFFF
	orl	r8, 0x2260
	ld.w	r9, r8[0]
	mov	r8, 0xF244
	st.w	r8[0], r9		/* port B @0xF244 */
	movh	r8, 0xFFFF
	orl	r8, 0x2460
	ld.w	r9, r8[0]
	mov	r8, 0xF248
	st.w	r8[0], r9		/* port C @0xF248 */
	movh	r8, 0xFFFF
	orl	r8, 0x2660
	ld.w	r9, r8[0]
	mov	r8, 0xF24C
	st.w	r8[0], r9		/* port D @0xF24C */
	popm	pc

/* hpoll: the handpiece ADC is an external SPI bus that main() samples ONCE at boot, then it's frozen
   (stock re-samples via a timer IRQ set up only in the control loop we replaced). Call 0x800146B8 to
   reload the SPI DMA + re-read, then classify adc(3) and steer the left paddle. Live bands (this unit):
   1000-1999 = CUT, 2000-2999 = COAG. Protects r0-r7 (the stock fn clobbers freely). */
hpoll:
	pushm	r0-r7, lr
	movh	r8, 0x8001
	orl	r8, 0x46b8
	icall	r8			/* 0x800146B8: reload SPI DMA, snapshot, filter */
	mov	r8, 0x29EA		/* adc(3) snapshot = handpiece switch level */
	ld.uh	r9, r8[0]
	mov	r8, 0xF0E0
	st.w	r8[0], r9		/* log the level */
	/* classify -> r12: 0=idle, 1=CUT (~2205), 2=COAG (~3166) */
	mov	r12, 0
	mov	r8, 1600
	cp.w	r9, r8
	brlt	.hp_cls			/* <1600 = idle */
	mov	r8, 2600
	cp.w	r9, r8
	brge	.hp_c2
	mov	r12, 1			/* 1600-2599 = CUT */
	rjmp	.hp_cls
.hp_c2:
	mov	r8, 2900
	cp.w	r9, r8
	brlt	.hp_cls			/* 2600-2899 = gap -> idle */
	mov	r12, 2			/* >=2900 = COAG */
.hp_cls:
	/* debounce: act only after 2+ consecutive frames of the same class (rejects the SPI
	   pipeline alias that briefly blips ~2328). last class @0xF0E4, stable count @0xF0E8. */
	mov	r8, 0xF0E4
	ld.w	r10, r8[0]
	cp.w	r10, r12
	breq	.hp_cnt
	st.w	r8[0], r12		/* class changed -> reset count */
	mov	r8, 0xF0E8
	mov	r10, 0
	st.w	r8[0], r10
	rjmp	.hp_done
.hp_cnt:
	mov	r8, 0xF0E8
	ld.w	r10, r8[0]
	sub	r10, -1
	st.w	r8[0], r10
	cp.w	r10, 2
	brlt	.hp_done		/* not stable yet */
	cp.w	r12, 1
	brne	.hp_tc2
	mov	r8, 0xF0F4		/* CUT -> paddle down */
	ld.w	r10, r8[0]
	sub	r10, 12
	cp.w	r10, 0
	brge	.hp_sd
	mov	r10, 0
.hp_sd:
	st.w	r8[0], r10
	rjmp	.hp_done
.hp_tc2:
	cp.w	r12, 2
	brne	.hp_done
	mov	r8, 0xF0F4		/* COAG -> paddle up */
	ld.w	r10, r8[0]
	sub	r10, -12
	mov	r11, 390
	cp.w	r10, r11
	brle	.hp_su
	mov	r10, 390
.hp_su:
	st.w	r8[0], r10
.hp_done:
	popm	r0-r7, pc

/* NEM port bicolor LED (active-low): pin95=PC31 @0xFFFF2400 mask 0x80000000, pin106=PD10 @0xFFFF2600
   mask 0x400. GREEN=95 high+106 low; RED=95 low+106 high; OFF=both high. These pins are used ONLY by
   the stock NEM LED code -> safe, no brownout. Leaf routines, clobber r8/r9 only. */
led_init:
	movh	r8, 0xFFFF
	orl	r8, 0x2400
	movh	r9, 0x8000
	st.w	r8[0x04], r9		/* pin95 GPERS */
	st.w	r8[0x44], r9		/* pin95 ODERS */
	movh	r8, 0xFFFF
	orl	r8, 0x2600
	mov	r9, 0x400
	st.w	r8[0x04], r9		/* pin106 GPERS */
	st.w	r8[0x44], r9		/* pin106 ODERS */
	mov	pc, lr
led_green:
	movh	r8, 0xFFFF
	orl	r8, 0x2400
	movh	r9, 0x8000
	st.w	r8[0x54], r9		/* pin95 high */
	movh	r8, 0xFFFF
	orl	r8, 0x2600
	mov	r9, 0x400
	st.w	r8[0x58], r9		/* pin106 low */
	mov	pc, lr
led_red:
	movh	r8, 0xFFFF
	orl	r8, 0x2400
	movh	r9, 0x8000
	st.w	r8[0x58], r9		/* pin95 low */
	movh	r8, 0xFFFF
	orl	r8, 0x2600
	mov	r9, 0x400
	st.w	r8[0x54], r9		/* pin106 high */
	mov	pc, lr
led_off:
	movh	r8, 0xFFFF
	orl	r8, 0x2400
	movh	r9, 0x8000
	st.w	r8[0x54], r9		/* pin95 high */
	movh	r8, 0xFFFF
	orl	r8, 0x2600
	mov	r9, 0x400
	st.w	r8[0x54], r9		/* pin106 high */
	mov	pc, lr

/* nemled: drive the NEM port LED. Green while playing; on a loss (AI score r7 goes up) flash red for
   ~30 frames. State: red-flash timer @0xF0D8, last AI score @0xF0DC. Preserves r0-r7. */
nemled:
	pushm	lr
	mov	r8, 0xF0DC
	ld.w	r9, r8[0]		/* last AI score */
	cp.w	r7, r9
	brle	.nl_tim
	mov	r10, 30			/* player lost a point -> start ~1.6s red flash */
	mov	r8, 0xF0D8
	st.w	r8[0], r10
.nl_tim:
	mov	r8, 0xF0DC
	st.w	r8[0], r7
	mov	r8, 0xF0D8
	ld.w	r9, r8[0]
	cp.w	r9, 0
	brle	.nl_green
	sub	r9, 1			/* red flash active: count down + blink red/off */
	st.w	r8[0], r9
	bfextu	r10, r9, 2, 1		/* bit2 -> toggle every 4 frames */
	cp.w	r10, 0
	brne	.nl_off
	rcall	led_red
	rjmp	.nl_done
.nl_off:
	rcall	led_off
	rjmp	.nl_done
.nl_green:
	rcall	led_green
.nl_done:
	popm	pc

/* score(r12=ls, r11=rs) */
score:
	pushm	r0-r7, lr
	mov	r0, r12
	mov	r1, r11
	mov	r12, 360
	mov	r11, 40
	mov	r10, 80
	mov	r9, 30
	lda.w	r8, c_blk
	rcall	rect
	sub	sp, 32
	mov	r5, sp
	mov	r12, r5
	mov	r11, r0
	rcall	put_int
	mov	r5, r12
	mov	r9, 32
	st.b	r5++, r9
	mov	r9, 58
	st.b	r5++, r9
	mov	r9, 32
	st.b	r5++, r9
	mov	r12, r5
	mov	r11, r1
	rcall	put_int
	mov	r5, r12
	mov	r9, 0
	st.b	r5[0], r9
	mov	r12, 360
	mov	r11, 44
	mov	r10, sp
	rcall	text
	sub	sp, -32
	popm	r0-r7, pc

/* scrinit: bring the SLCD5 out of its cold-boot splash the way stock firmware does, then set up
   Pong. The boot logo is an IMAGE object (xi64) that `z` does NOT remove; `xd 0 255` deletes it.
   m23 = version query (panel replies when ready -> shows in RX log @0xF100). s1 0 = select screen.
   Clobbers r8-r12; preserves r0-r7 (emit leaves them, text saves them). */
scrinit:
	pushm	lr
	lda.w	r12, s_m23		/* flush + version query (panel answers once booted) */
	rcall	emit
	lda.w	r12, s_xd		/* delete all image objects -> removes the logo splash */
	rcall	emit
	lda.w	r12, s_mpop		/* pop any splash macros */
	rcall	emit
	lda.w	r12, s_s1		/* select screen 0 */
	rcall	emit
	lda.w	r12, s_z		/* clear primitives */
	rcall	emit
	mov	r12, 340
	mov	r11, 10
	lda.w	r10, s_pong
	rcall	text
	popm	pc

emit:
	pushm	lr
	mov	r10, r12
.e_l:
	ld.ub	r11, r10++
	cp.w	r11, 0
	breq	.e_cr
	rcall	putc1
	rjmp	.e_l
.e_cr:
	mov	r11, 13
	rcall	putc1
	popm	pc
putc1:
	movh	r8, 0xFFFF
	orl	r8, 0x2C00
	mov	r12, 200000
.pw:
	ld.w	r9, r8[0x14]
	bfextu	r9, r9, 1, 1
	cp.w	r9, 0
	brne	.prdy
	sub	r12, 1
	cp.w	r12, 0
	brne	.pw
	mov	pc, lr
.prdy:
	st.w	r8[0x1c], r11
	mov	pc, lr

put_int:
	sub	sp, 16
	cp.w	r11, 0
	brge	.pi_pos
	mov	r9, 45
	st.b	r12++, r9
	neg	r11
.pi_pos:
	mov	r10, sp
	cp.w	r11, 0
	brne	.pi_loop
	mov	r9, 48
	st.b	r10++, r9
	rjmp	.pi_rev
.pi_loop:
	mov	r8, 0
.pi_div:
	cp.w	r11, 10
	brlt	.pi_dd
	sub	r11, 10
	sub	r8, -1
	rjmp	.pi_div
.pi_dd:
	mov	r9, r11
	sub	r9, -48
	st.b	r10++, r9
	mov	r11, r8
	cp.w	r11, 0
	brne	.pi_loop
.pi_rev:
	cp.w	r10, sp
	brls	.pi_done
	sub	r10, 1
	ld.ub	r9, r10[0]
	st.b	r12++, r9
	rjmp	.pi_rev
.pi_done:
	sub	sp, -16
	mov	pc, lr

rect:
	pushm	r0-r7, lr
	add	r10, r12
	add	r9, r11
	mov	r0, r12
	mov	r1, r11
	mov	r2, r10
	mov	r3, r9
	mov	r4, r8
	sub	sp, 48
	mov	r5, sp
	mov	r9, 114
	st.b	r5++, r9
	mov	r9, 32
	st.b	r5++, r9
	mov	r12, r5
	mov	r11, r0
	rcall	put_int
	mov	r5, r12
	mov	r9, 32
	st.b	r5++, r9
	mov	r12, r5
	mov	r11, r1
	rcall	put_int
	mov	r5, r12
	mov	r9, 32
	st.b	r5++, r9
	mov	r12, r5
	mov	r11, r2
	rcall	put_int
	mov	r5, r12
	mov	r9, 32
	st.b	r5++, r9
	mov	r12, r5
	mov	r11, r3
	rcall	put_int
	mov	r5, r12
	mov	r9, 32
	st.b	r5++, r9
	mov	r9, 49
	st.b	r5++, r9
	mov	r9, 32
	st.b	r5++, r9
.rc_col:
	ld.ub	r9, r4++
	cp.w	r9, 0
	breq	.rc_cold
	st.b	r5++, r9
	rjmp	.rc_col
.rc_cold:
	mov	r9, 0
	st.b	r5[0], r9
	mov	r12, sp
	rcall	emit
	sub	sp, -48
	popm	r0-r7, pc

text:
	pushm	r0-r7, lr
	mov	r0, r12
	mov	r1, r11
	mov	r2, r10
	sub	sp, 64
	mov	r5, sp
	mov	r9, 116
	st.b	r5++, r9
	mov	r9, 32
	st.b	r5++, r9
	mov	r9, 34
	st.b	r5++, r9
.tx_s:
	ld.ub	r9, r2++
	cp.w	r9, 0
	breq	.tx_se
	st.b	r5++, r9
	rjmp	.tx_s
.tx_se:
	mov	r9, 34
	st.b	r5++, r9
	mov	r9, 32
	st.b	r5++, r9
	mov	r12, r5
	mov	r11, r0
	rcall	put_int
	mov	r5, r12
	mov	r9, 32
	st.b	r5++, r9
	mov	r12, r5
	mov	r11, r1
	rcall	put_int
	mov	r5, r12
	mov	r9, 0
	st.b	r5[0], r9
	mov	r12, sp
	rcall	emit
	sub	sp, -64
	popm	r0-r7, pc

	.align	2
s_m23:	.asciz	"\r\r\rm23"
s_xd:	.asciz	"xd 0 255"
s_mpop:	.asciz	"mpop -1"
s_s1:	.asciz	"s1 0"
s_x90:	.asciz	"xset 90 -b"
s_x91:	.asciz	"xset 91 -b"
s_b0:	.asciz	"bdc 90 10 10 1 \"UP\" 150 200"
s_b1:	.asciz	"bdc 91 10 270 1 \"DN\" 150 200"
s_ton:	.asciz	"touch on"
s_pong:	.asciz	"PONG"
s_z:	.asciz	"z"
c_blk:	.asciz	"000"
c_wht:	.asciz	"fff"
c_grn:	.asciz	"0f0"
