/* NEM-port LED pin sweep. Drives each SAFE candidate GPIO high in turn (all others low), ~4s each,
 * showing "PIN <n>" on the SLCD5. Watch the NEM port; when it lights / changes, read the number.
 * Candidates (global pin = port*32+bit): 23,24 (PA23/24 = monitoring-healthy status pins -> top
 * suspects), 71 (PC7), 88 (PC24), 35 (PB3) init enables, 105 (PD9) mode indicator. NONE of the
 * RF-output-stage or relay pins are touched. Hook 0x80014AE4, direct USART1 draw, same as pong. */
	.text
	.global	game_entry
game_entry:
	mov	r0, 0			/* pin index 0..5 */
.sw_show:
	rcall	clrscr			/* kill splash + clear (re-sent each phase -> self-heals cold boot) */
	mov	r2, 0			/* drive ALL candidates low first */
.sw_clr:
	mov	r3, r2
	lsl	r3, 3
	lda.w	r4, pintab
	add	r4, r3
	ld.w	r11, r4[0]
	ld.w	r10, r4[4]
	mov	r9, 0
	rcall	pinset
	sub	r2, -1
	cp.w	r2, 6
	brlt	.sw_clr
	mov	r3, r0			/* drive the current pin high */
	lsl	r3, 3
	lda.w	r4, pintab
	add	r4, r3
	ld.w	r11, r4[0]
	ld.w	r10, r4[4]
	mov	r9, 1
	rcall	pinset
	mov	r3, r0			/* draw "PIN <num>" */
	lsl	r3, 2
	lda.w	r4, pinnums
	add	r4, r3
	ld.w	r1, r4[0]
	rcall	drawpin
	mov	r7, 440			/* ~4s hold = 440 * 50000 */
.sw_do:
	mov	r8, 50000
.sw_di:
	sub	r8, 1
	cp.w	r8, 0
	brne	.sw_di
	sub	r7, 1
	cp.w	r7, 0
	brne	.sw_do
	sub	r0, -1
	cp.w	r0, 6
	brlt	.sw_show
	mov	r0, 0
	rjmp	.sw_show

/* pinset: r11=port base, r10=mask, r9=1 high / 0 low. Forces GPIO output then sets the level. */
pinset:
	st.w	r11[0x04], r10		/* GPERS: GPIO mode */
	st.w	r11[0x44], r10		/* ODERS: output enable */
	cp.w	r9, 0
	breq	.ps_lo
	st.w	r11[0x54], r10		/* OVRS: drive high */
	mov	pc, lr
.ps_lo:
	st.w	r11[0x58], r10		/* OVRC: drive low */
	mov	pc, lr

/* drawpin: r1 = pin number -> emit  t "PIN <n>" 250 220 */
drawpin:
	pushm	r0-r7, lr
	sub	sp, 48
	mov	r5, sp
	mov	r9, 116
	st.b	r5++, r9		/* t */
	mov	r9, 32
	st.b	r5++, r9
	mov	r9, 34
	st.b	r5++, r9		/* " */
	mov	r9, 80
	st.b	r5++, r9		/* P */
	mov	r9, 73
	st.b	r5++, r9		/* I */
	mov	r9, 78
	st.b	r5++, r9		/* N */
	mov	r9, 32
	st.b	r5++, r9
	mov	r12, r5
	mov	r11, r1
	rcall	put_int
	mov	r5, r12
	mov	r9, 34
	st.b	r5++, r9		/* " */
	mov	r9, 32
	st.b	r5++, r9
	mov	r12, r5
	mov	r11, 250
	rcall	put_int
	mov	r5, r12
	mov	r9, 32
	st.b	r5++, r9
	mov	r12, r5
	mov	r11, 220
	rcall	put_int
	mov	r5, r12
	mov	r9, 0
	st.b	r5[0], r9
	mov	r12, sp
	rcall	emit
	sub	sp, -48
	popm	r0-r7, pc

clrscr:
	pushm	lr
	lda.w	r12, s_m23
	rcall	emit
	lda.w	r12, s_xd
	rcall	emit
	lda.w	r12, s_z
	rcall	emit
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

	.align	2
s_m23:	.asciz	"\r\r\rm23"
s_xd:	.asciz	"xd 0 255"
s_z:	.asciz	"z"
	.align	2
pintab:
	.long	0xFFFF2000, 0x00800000	/* 23 PA23 */
	.long	0xFFFF2000, 0x01000000	/* 24 PA24 */
	.long	0xFFFF2400, 0x00000080	/* 71 PC7  */
	.long	0xFFFF2400, 0x01000000	/* 88 PC24 */
	.long	0xFFFF2600, 0x00000200	/* 105 PD9 */
	.long	0xFFFF2200, 0x00000008	/* 35 PB3  */
pinnums:
	.long	23, 24, 71, 88, 105, 35
