/* RAYCASTER on the AEX (hook 0x80014AE4, direct USART1 draw -- same plumbing as pongall.s).
 * Wolf3D-style maze, COLS ray columns x COLW px (set in raygen.py). You auto-walk forward (sliding
 * along walls); PlasmaBlade CUT = turn left, COAG = turn right. Collect the NKEYS gold keys: the exit
 * is red/locked until then, green after -- walk into it to escape.
 * NEM port LED = key compass: green when facing the nearest key (or the open exit), red when facing
 * away; blinks faster the closer it is. Sound = the SLCD5 buzzer (bfs<Hz> / beep<ms> / bvs<vol>),
 * the same path the stock firmware uses for every tone (serial text only, no RF coupling).
 * The bottleneck is 115200-baud panel commands, not the CPU: only columns whose height/colour/key
 * sprite changed are redrawn (a shrinking column repaints just its ceiling/floor strips).
 * Tables/map come from raygen.py (-> raytab.s); its --preview renders the same math to PNG.
 * State: r7 = 0xF000 base for the whole game (rect/emit/text/hpoll all preserve r0-r7).
 *   0x00 frame  0x04 px  0x08 py (Q16 tiles)  0x0C pa (0..1023)  0x10 cos  0x14 sin (Q14)
 *   0x18 last handpiece class  0x20 debounced class  0x24 keys found  0x28 bumped-last-frame
 *   0x2C HUD dirty  0x30 LED last toggle (COUNT)  0x34 LED blink phase
 *   0x38 ksel sig  0x3C ksel slot  0x40+k*4 key alive  0x60+k*16 key view {valid, depth, left, S}
 *   0xE0 tmp  0x100+c*4 drawn h  0x300+c*4 drawn colour  0x500+c*4 drawn key sig  0x700 HUD text
 */
	.text
	.global	game_entry
	.equ	TURN, 24		/* angle units per frame (1024 = full turn) -- bench knob */
	.equ	SPEED, 6554		/* auto-walk, Q16 tiles per frame (0.1 tile) -- bench knob */
	.equ	MARGIN, 16384		/* Q16 wall clearance (0.25 tile) */
	.equ	PICK, 29491		/* Q16 pickup radius (0.45 tile) */
	.equ	HUDCOLS, 12		/* columns under the HUD text: redrawing one re-sends the text */
	.equ	NOTE_MS, 100		/* tune note spacing */
	.equ	COUNT, 0x108		/* AVR32 cycle counter sysreg, 48 MHz */
game_entry:
	mov	r7, 0xF000
	mov	r9, 0
	st.w	r7[0x00], r9
	st.w	r7[0x18], r9
	st.w	r7[0x20], r9
	st.w	r7[0x28], r9
	st.w	r7[0x30], r9
	st.w	r7[0x34], r9
	rcall	led_init
	/* cold boot: the panel ignores setup (logo stays) for ~5 s after power-on. Frame count is no
	   clock here (a blocked player = near-empty frames), so wait by spinning: 4 sends ~1.3 s apart. */
	mov	r6, 4
.boot:
	rcall	redraw
	movh	r8, 0x0100		/* ~16M spins, same as the win pause */
.bw:
	sub	r8, 1
	cp.w	r8, 0
	brne	.bw
	sub	r6, 1
	cp.w	r6, 0
	brne	.boot
	rcall	reset
.loop:
	ld.w	r9, r7[0x00]
	sub	r9, -1
	st.w	r7[0x00], r9
	rcall	hpoll
	ld.w	r12, r7[0x20]
	ld.w	r9, r7[0x0C]
	cp.w	r12, 1
	brne	.t2
	sub	r9, TURN		/* CUT -> left */
.t2:
	cp.w	r12, 2
	brne	.t3
	sub	r9, -TURN		/* COAG -> right */
.t3:
	andl	r9, 1023, COH
	st.w	r7[0x0C], r9
	lda.w	r10, sintab
	ld.sh	r11, r10[r9 << 1]
	st.w	r7[0x14], r11		/* sin(pa) */
	sub	r9, -256
	andl	r9, 1023, COH
	ld.sh	r11, r10[r9 << 1]
	st.w	r7[0x10], r11		/* cos(pa) */
	/* auto-walk with wall sliding: x and y tried independently. r4 = moved, r5 = hit locked exit */
	ld.w	r0, r7[0x04]
	ld.w	r1, r7[0x08]
	mov	r9, SPEED
	ld.w	r8, r7[0x10]
	mul	r8, r9
	asr	r2, r8, 14		/* dx */
	ld.w	r8, r7[0x14]
	mul	r8, r9
	asr	r3, r8, 14		/* dy */
	mov	r4, 0
	mov	r5, 0
	mov	r12, r0
	add	r12, r2			/* nx */
	mov	r11, r12
	mov	r8, MARGIN
	cp.w	r2, 0
	brge	.mx1
	neg	r8
.mx1:
	add	r11, r8
	mov	r10, r1
	rcall	tile
	cp.w	r9, 0
	brne	.mxb
	mov	r0, r12
	mov	r4, 1
	rjmp	.my
.mxb:
	cp.w	r9, 3
	brne	.my
	ld.w	r8, r7[0x24]
	cp.w	r8, NKEYS
	brge	.win
	mov	r5, 1
.my:
	mov	r12, r1
	add	r12, r3			/* ny */
	mov	r10, r12
	mov	r8, MARGIN
	cp.w	r3, 0
	brge	.my1
	neg	r8
.my1:
	add	r10, r8
	mov	r11, r0
	rcall	tile
	cp.w	r9, 0
	brne	.myb
	mov	r1, r12
	mov	r4, 1
	rjmp	.mv
.myb:
	cp.w	r9, 3
	brne	.mv
	ld.w	r8, r7[0x24]
	cp.w	r8, NKEYS
	brge	.win
	mov	r5, 1
.mv:
	st.w	r7[0x04], r0
	st.w	r7[0x08], r1
	/* bump sound once per stop (not every frame while pinned against a wall) */
	cp.w	r4, 0
	brne	.moved
	ld.w	r8, r7[0x28]
	cp.w	r8, 0
	brne	.bdone
	mov	r8, 1
	st.w	r7[0x28], r8
	lda.w	r12, s_bump
	cp.w	r5, 0
	breq	.b1
	lda.w	r12, s_lock		/* locked exit: lower, longer buzz */
.b1:
	rcall	emit
	rjmp	.bdone
.moved:
	mov	r8, 0
	st.w	r7[0x28], r8
.bdone:
	rcall	pickup
	rcall	keyprep
	rcall	render
	rcall	hud
	rcall	compass
	mov	r8, 100000
.dl:
	sub	r8, 1
	cp.w	r8, 0
	brne	.dl
	rjmp	.loop
.win:
	lda.w	r12, t_win
	rcall	tune
	mov	r12, 330
	mov	r11, 225
	lda.w	r10, s_win
	rcall	text
	movh	r8, 0x0100		/* ~16M spins = a couple of seconds */
.wl:
	sub	r8, 1
	cp.w	r8, 0
	brne	.wl
	rcall	reset
	rjmp	.loop

/* tile(r11=x, r10=y Q16) -> r9 = map tile. Leaf, clobbers r8/r9. */
tile:
	asr	r8, r10, 16
	lsl	r8, 4
	asr	r9, r11, 16
	add	r8, r9
	lda.w	r9, maptab
	ld.ub	r9, r9[r8]
	mov	pc, lr

/* reset: player to (1.5,1.5) facing east, all keys back, full redraw */
reset:
	pushm	lr
	mov	r9, 0x18000
	st.w	r7[0x04], r9
	st.w	r7[0x08], r9
	mov	r9, 0
	st.w	r7[0x0C], r9
	st.w	r7[0x24], r9
	mov	r9, 1
	mov	r10, r7
	mov	r11, NKEYS
.rsk:
	st.w	r10[0x40], r9
	sub	r10, -4
	sub	r11, 1
	cp.w	r11, 0
	brne	.rsk
	rcall	redraw
	popm	pc

/* redraw: panel out of its splash (see pongall.s scrinit), buzzer volume, paint ceiling/floor,
   forget what every column showed so the next render draws them all. */
redraw:
	pushm	lr
	lda.w	r12, s_m23
	rcall	emit
	lda.w	r12, s_xd
	rcall	emit
	lda.w	r12, s_mpop
	rcall	emit
	lda.w	r12, s_s1
	rcall	emit
	lda.w	r12, s_z
	rcall	emit
	lda.w	r12, s_vol
	rcall	emit
	mov	r12, 0
	mov	r11, 0
	mov	r10, 800
	mov	r9, 240
	lda.w	r8, c_ceil
	rcall	rect
	mov	r12, 0
	mov	r11, 240
	mov	r10, 800
	mov	r9, 240
	lda.w	r8, c_floor
	rcall	rect
	mov	r9, 0
	mov	r10, -1
	mov	r11, r7
	mov	r12, COLS
.rdc:
	st.w	r11[0x100], r9
	st.w	r11[0x300], r10
	st.w	r11[0x500], r9
	sub	r11, -4
	sub	r12, 1
	cp.w	r12, 0
	brne	.rdc
	mov	r9, 1
	st.w	r7[0x2C], r9
	popm	pc

/* inval(r12 = number of columns from 0): force a full repaint of those columns next render
   (drawn sig = -1 never matches) and re-send the HUD. Used when HUD text or exit colour changes. */
inval:
	mov	r10, r7
	mov	r9, -1
.iv:
	st.w	r10[0x500], r9
	sub	r10, -4
	sub	r12, 1
	cp.w	r12, 0
	brne	.iv
	mov	r9, 1
	st.w	r7[0x2C], r9
	mov	pc, lr

/* pickup: collect any live key within PICK of the player; all found -> exit opens */
pickup:
	pushm	r0-r7, lr
	mov	r0, 0
	lda.w	r1, keytab
.pk:
	add	r2, r7, r0 << 2
	ld.w	r3, r2[0x40]
	cp.w	r3, 0
	breq	.pkn
	ld.w	r8, r1[0]
	ld.w	r9, r7[0x04]
	sub	r8, r9
	abs	r8
	cp.w	r8, PICK
	brge	.pkn
	ld.w	r8, r1[4]
	ld.w	r9, r7[0x08]
	sub	r8, r9
	abs	r8
	cp.w	r8, PICK
	brge	.pkn
	mov	r3, 0
	st.w	r2[0x40], r3
	ld.w	r3, r7[0x24]
	sub	r3, -1
	st.w	r7[0x24], r3
	mov	r12, HUDCOLS
	rcall	inval
	lda.w	r12, t_pick
	rcall	tune
	ld.w	r3, r7[0x24]
	cp.w	r3, NKEYS
	brlt	.pkn
	mov	r12, COLS		/* exit turns green: repaint everything once */
	rcall	inval
	lda.w	r12, t_open
	rcall	tune
.pkn:
	sub	r1, -8
	sub	r0, -1
	cp.w	r0, NKEYS
	brlt	.pk
	popm	r0-r7, pc

/* keyprep: per live key, camera-space depth + screen box. Mirrors raygen.py:keyview. */
keyprep:
	pushm	r0-r7, lr
	mov	r0, 0
	lda.w	r1, keytab
.kp:
	mov	r2, r0
	lsl	r2, 4
	add	r2, r7			/* r2[0x60..] = this key's view slot */
	mov	r3, 0
	st.w	r2[0x60], r3		/* invalid unless proven visible */
	add	r8, r7, r0 << 2
	ld.w	r8, r8[0x40]
	cp.w	r8, 0
	breq	.kpn
	ld.w	r3, r1[0]
	ld.w	r8, r7[0x04]
	sub	r3, r8
	asr	r3, 4			/* dx Q12 */
	ld.w	r4, r1[4]
	ld.w	r8, r7[0x08]
	sub	r4, r8
	asr	r4, 4			/* dy Q12 */
	ld.w	r5, r7[0x10]		/* cos */
	ld.w	r6, r7[0x14]		/* sin */
	mul	r8, r3, r5
	mul	r9, r4, r6
	add	r8, r9
	asr	r8, 14			/* depth */
	cp.w	r8, 1024
	brlt	.kpn			/* behind or < 0.25 tile: skip */
	mul	r9, r4, r5
	mul	r10, r3, r6
	sub	r9, r10
	asr	r9, 14			/* lateral, + = right */
	st.w	r2[0x64], r8
	mov	r10, 693
	mul	r9, r10
	divs	r10, r9, r8		/* r10 = lat*693/depth (truncating, like raygen tdiv) */
	sub	r10, -400		/* screen centre x */
	movh	r12, (HKEY >> 16)
	orl	r12, (HKEY & 0xFFFF)
	divu	r4, r12, r8		/* r4 = S (r5 = remainder) */
	mov	r9, 400
	cp.w	r4, r9
	brle	.kps
	mov	r4, 400
.kps:
	lsr	r9, r4, 1
	sub	r10, r9			/* left */
	st.w	r2[0x68], r10
	st.w	r2[0x6C], r4
	mov	r3, 1
	st.w	r2[0x60], r3
.kpn:
	sub	r1, -8
	sub	r0, -1
	cp.w	r0, NKEYS
	brlt	.kp
	popm	r0-r7, pc

/* ksel(r0 = column, r1 = wall perp): nearest visible key overlapping this column and in front of
   its wall -> 0x38 sig (0 = none; else packs left/S so any change forces a repaint), 0x3C slot.
   ponytail: one key per column; two keys stacked in one column show only the nearer. */
ksel:
	pushm	r0-r7, lr
	mov	r2, r1			/* best depth so far = the wall */
	mov	r3, 0
	mov	r4, COLW
	mul	r4, r0			/* column x0 */
	mov	r5, r4
	mov	r9, COLW
	add	r5, r9			/* column x1 */
	mov	r6, 0
	mov	r8, r7
	sub	r8, -0x60
.ks:
	ld.w	r9, r8[0]
	cp.w	r9, 0
	breq	.ksn
	ld.w	r9, r8[4]
	cp.w	r9, r2
	brge	.ksn
	ld.w	r10, r8[8]
	cp.w	r10, r5
	brge	.ksn
	ld.w	r11, r8[12]
	add	r11, r10
	cp.w	r11, r4
	brle	.ksn
	mov	r2, r9
	mov	r3, r8
.ksn:
	sub	r8, -16
	sub	r6, -1
	cp.w	r6, NKEYS
	brlt	.ks
	mov	r9, 0
	cp.w	r3, 0
	breq	.ksd
	ld.w	r9, r3[8]
	andl	r9, 0x7FF, COH
	ld.w	r10, r3[12]
	lsl	r10, 11
	or	r9, r10
	movh	r10, 0x0020		/* bit 21 = present */
	or	r9, r10
.ksd:
	st.w	r7[0x38], r9
	st.w	r7[0x3C], r3
	popm	r0-r7, pc

/* kdraw(r12 = key view slot, r11 = column x0): the key's shape rects, clipped to this column.
   Mirrors raygen.py:keyrects + the preview's clip. */
kdraw:
	pushm	r0-r7, lr
	ld.w	r2, r12[12]		/* S */
	ld.w	r3, r12[8]		/* left */
	mov	r4, 240
	lsr	r8, r2, 2
	sub	r4, r8			/* box top */
	mov	r5, r11
	mov	r6, r11
	mov	r9, COLW
	add	r6, r9
	lda.w	r0, kshape
	mov	r1, NSHAPE
.kd:
	ld.ub	r8, r0[0]
	mul	r8, r2
	asr	r8, 4
	add	r8, r3			/* X0 */
	cp.w	r8, r5
	brge	.kd1
	mov	r8, r5
.kd1:
	ld.ub	r9, r0[2]
	mul	r9, r2
	asr	r9, 4
	add	r9, r3			/* X1 */
	cp.w	r9, r6
	brle	.kd2
	mov	r9, r6
.kd2:
	cp.w	r9, r8
	brle	.kdn
	sub	r10, r9, r8		/* w */
	mov	r12, r8
	ld.ub	r8, r0[1]
	mul	r8, r2
	asr	r8, 4
	add	r8, r4			/* Y0 */
	cp.w	r8, 0
	brge	.kd3
	mov	r8, 0
.kd3:
	ld.ub	r9, r0[3]
	mul	r9, r2
	asr	r9, 4
	add	r9, r4			/* Y1 */
	mov	r11, 480
	cp.w	r9, r11
	brle	.kd4
	mov	r9, r11
.kd4:
	cp.w	r9, r8
	brle	.kdn
	sub	r9, r8			/* h */
	mov	r11, r8
	ld.ub	r8, r0[4]		/* colour offset */
	lda.w	r7, c_key
	add	r8, r7
	rcall	rect
.kdn:
	sub	r0, -8
	sub	r1, 1
	cp.w	r1, 0
	brne	.kd
	popm	r0-r7, pc

/* render: cast COLS rays and redraw the columns that changed. Mirrors raygen.py:cast exactly.
   r0=c r1,r2=ray x,y r3,r4=step r5=count/slot r6=tile->colour index */
render:
	pushm	r0-r7, lr
	mov	r0, 0
.rc:
	lda.w	r8, coloff
	ld.sh	r9, r8[r0 << 1]
	ld.w	r8, r7[0x0C]
	add	r9, r8
	andl	r9, 1023, COH
	lda.w	r10, sintab
	ld.sh	r4, r10[r9 << 1]
	asr	r4, 3			/* sy: 1/32-tile step */
	sub	r9, -256
	andl	r9, 1023, COH
	ld.sh	r3, r10[r9 << 1]
	asr	r3, 3			/* sx */
	ld.w	r1, r7[0x04]
	ld.w	r2, r7[0x08]
	mov	r5, 600			/* guard; the solid border stops every ray long before */
	lda.w	r12, maptab
.mr:
	add	r1, r3
	add	r2, r4
	asr	r8, r2, 16
	lsl	r8, 4
	asr	r9, r1, 16
	add	r8, r9
	ld.ub	r6, r12[r8]
	cp.w	r6, 0
	brne	.hit
	sub	r5, 1
	cp.w	r5, 0
	brne	.mr
	mov	r6, 1
.hit:
	/* face: crossed into a new x cell on the last step -> x face (lit), else y face (shaded) */
	asr	r8, r1, 16
	sub	r9, r1, r3
	asr	r9, 16
	mov	r11, 0
	cp.w	r8, r9
	brne	.sd
	mov	r11, 4
.sd:
	cp.w	r6, 3			/* exit still locked -> draw it as tile 4 (red) */
	brne	.nl
	ld.w	r8, r7[0x24]
	cp.w	r8, NKEYS
	brge	.nl
	mov	r6, 4
.nl:
	sub	r6, 1
	lsl	r6, 3
	add	r6, r11			/* (tile-1)*8 + side*4 */
	/* bisect back toward the face: 5 halvings -> 1/1024 tile, kills the step wobble */
	sub	r1, r3
	sub	r2, r4
	mov	r5, 5
.rf:
	asr	r3, 1
	asr	r4, 1
	add	r1, r3
	add	r2, r4
	asr	r8, r2, 16
	lsl	r8, 4
	asr	r9, r1, 16
	add	r8, r9
	ld.ub	r9, r12[r8]
	cp.w	r9, 0
	breq	.rf1
	sub	r1, r3
	sub	r2, r4
.rf1:
	sub	r5, 1
	cp.w	r5, 0
	brne	.rf
	/* perpendicular distance (no fisheye) = dot(hit - player, view dir), Q12 tiles */
	ld.w	r8, r7[0x04]
	sub	r1, r8
	asr	r1, 4
	ld.w	r8, r7[0x10]
	mul	r1, r8
	ld.w	r8, r7[0x08]
	sub	r2, r8
	asr	r2, 4
	ld.w	r8, r7[0x14]
	mul	r2, r8
	add	r1, r2
	asr	r1, 14
	cp.w	r1, 64
	brge	.pp
	mov	r1, 64
.pp:
	movh	r8, (HK >> 16)
	orl	r8, (HK & 0xFFFF)
	divu	r10, r8, r1		/* r10 = HK / perp (r11 = remainder, unused) */
	mov	r8, 480
	cp.w	r10, r8
	brle	.hc
	mov	r10, 480
.hc:
	andl	r10, 0xFFFC		/* multiple of 4: fewer tiny changes = fewer bytes on the wire */
	mov	r9, 0			/* fog band */
	cp.w	r1, 8192
	brlt	.fg
	mov	r9, 1
	cp.w	r1, 16384
	brlt	.fg
	mov	r9, 2
	cp.w	r1, 28672
	brlt	.fg
	mov	r9, 3
.fg:
	add	r6, r9			/* r6 = colour index */
	st.w	r7[0xE0], r10
	rcall	ksel			/* r0 = c, r1 = perp -> 0x38 sig, 0x3C slot */
	ld.w	r1, r7[0xE0]		/* r1 = h */
	add	r5, r7, r0 << 2
	ld.w	r2, r5[0x100]		/* old h */
	ld.w	r3, r5[0x300]		/* old colour */
	ld.w	r8, r5[0x500]		/* old key sig */
	ld.w	r9, r7[0x38]		/* new key sig */
	mov	r4, COLW
	mul	r4, r0			/* x0 */
	or	r10, r8, r9
	cp.w	r10, 0
	breq	.diff			/* no key here now or before: cheap differential path */
	cp.w	r1, r2
	brne	.full
	cp.w	r6, r3
	brne	.full
	cp.w	r8, r9
	breq	.next
.full:
	/* key involved: repaint the whole column (ceiling, wall, floor), then the key on top */
	st.w	r5[0x100], r1
	st.w	r5[0x300], r6
	st.w	r5[0x500], r9
	mov	r2, 240
	lsr	r8, r1, 1
	sub	r2, r8			/* top */
	cp.w	r2, 0
	brle	.fu1
	mov	r12, r4
	mov	r11, 0
	mov	r10, COLW
	mov	r9, r2
	lda.w	r8, c_ceil
	rcall	rect
.fu1:
	mov	r12, r4
	mov	r11, r2
	mov	r10, COLW
	mov	r9, r1
	lda.w	r8, colors
	add	r8, r8, r6 << 2
	rcall	rect
	mov	r11, r2
	add	r11, r1			/* bottom */
	mov	r9, 480
	sub	r9, r11
	cp.w	r9, 0
	brle	.fu2
	mov	r12, r4
	mov	r10, COLW
	lda.w	r8, c_floor
	rcall	rect
.fu2:
	ld.w	r12, r7[0x3C]
	cp.w	r12, 0
	breq	.drawn
	mov	r11, r4
	rcall	kdraw
	rjmp	.drawn
.diff:
	cp.w	r1, r2
	brne	.dch
	cp.w	r6, r3
	breq	.next
.dch:
	st.w	r5[0x100], r1
	st.w	r5[0x300], r6
	cp.w	r1, r2
	brge	.dwall			/* grew / recoloured: one wall rect covers it */
	sub	r2, r1
	lsr	r2, 1			/* shrank: strip height d = (oh-h)/2 */
	mov	r12, r4
	mov	r11, 240
	lsr	r8, r1, 1
	sub	r11, r8
	sub	r11, r2			/* old top */
	mov	r10, COLW
	mov	r9, r2
	lda.w	r8, c_ceil
	rcall	rect
	mov	r12, r4
	mov	r11, 240
	lsr	r8, r1, 1
	add	r11, r8			/* new bottom */
	mov	r10, COLW
	mov	r9, r2
	lda.w	r8, c_floor
	rcall	rect
	cp.w	r6, r3
	breq	.drawn
.dwall:
	mov	r12, r4
	mov	r11, 240
	lsr	r8, r1, 1
	sub	r11, r8
	mov	r10, COLW
	mov	r9, r1
	lda.w	r8, colors
	add	r8, r8, r6 << 2
	rcall	rect
.drawn:
	cp.w	r0, HUDCOLS		/* painted under the HUD -> re-send its text */
	brge	.next
	mov	r8, 1
	st.w	r7[0x2C], r8
.next:
	sub	r0, -1
	cp.w	r0, COLS
	brlt	.rc
	popm	r0-r7, pc

/* hud: if dirty, "KEYS n/N" (or the EXIT OPEN variant) top-left */
hud:
	pushm	r0-r7, lr
	ld.w	r8, r7[0x2C]
	cp.w	r8, 0
	breq	.hd
	mov	r8, 0
	st.w	r7[0x2C], r8
	ld.w	r0, r7[0x24]
	lda.w	r1, s_hud
	cp.w	r0, NKEYS
	brlt	.h1
	lda.w	r1, s_hudopen
.h1:
	mov	r2, r7
	sub	r2, -0x700
.hcp:
	ld.ub	r3, r1++
	st.b	r2++, r3
	cp.w	r3, 0
	brne	.hcp
	mov	r2, r7
	sub	r2, -0x700
	mov	r3, r0
	sub	r3, -48
	st.b	r2[5], r3		/* "KEYS n/N": n at [5], N at [7] */
	mov	r3, NKEYS + 48
	st.b	r2[7], r3
	mov	r12, 12
	mov	r11, 12
	mov	r10, r2
	rcall	text
.hd:
	popm	r0-r7, pc

/* compass: NEM LED points at the nearest live key (Manhattan), or the exit once open.
   Green = target inside the 60-degree view cone, red = not. Blink half-period 50 ms + 40 ms/tile;
   within 1 tile it holds solid. Timed by the COUNT cycle counter, not frames. */
compass:
	pushm	r0-r7, lr
	ld.w	r0, r7[0x04]
	ld.w	r1, r7[0x08]
	ld.w	r8, r7[0x24]
	cp.w	r8, NKEYS
	brlt	.cpk
	mov	r3, EXITX
	mov	r4, EXITY
	rjmp	.cpt
.cpk:
	movh	r2, 0x7FFF		/* best distance */
	mov	r5, 0
	lda.w	r6, keytab
.cpl:
	add	r8, r7, r5 << 2
	ld.w	r8, r8[0x40]
	cp.w	r8, 0
	breq	.cpn
	ld.w	r9, r6[0]
	sub	r9, r0
	abs	r9
	ld.w	r10, r6[4]
	sub	r10, r1
	abs	r10
	add	r9, r10
	cp.w	r9, r2
	brge	.cpn
	mov	r2, r9
	ld.w	r3, r6[0]
	ld.w	r4, r6[4]
.cpn:
	sub	r6, -8
	sub	r5, -1
	cp.w	r5, NKEYS
	brlt	.cpl
.cpt:
	sub	r3, r0
	sub	r4, r1			/* r3,r4 = target - player (Q16) */
	mov	r2, r3
	abs	r2
	mov	r9, r4
	abs	r9
	add	r2, r9			/* r2 = Manhattan distance */
	asr	r3, 4
	asr	r4, 4
	ld.w	r5, r7[0x10]
	ld.w	r6, r7[0x14]
	mul	r8, r3, r5
	mul	r9, r4, r6
	add	r8, r9
	asr	r8, 14			/* depth */
	mul	r9, r4, r5
	mul	r10, r3, r6
	sub	r9, r10
	asr	r9, 14
	abs	r9			/* |lateral| */
	mov	r0, 0			/* facing? */
	cp.w	r8, 0
	brle	.cpf
	mov	r10, 7
	mul	r9, r10
	lsl	r8, 2
	cp.w	r9, r8			/* |lat|/depth < tan30 ~ 4/7 */
	brge	.cpf
	mov	r0, 1
.cpf:
	mov	r1, 1			/* lit? */
	mov	r8, 65536
	cp.w	r2, r8
	brlt	.cpo			/* within a tile: solid */
	asr	r2, 4
	mov	r9, 469			/* COUNT ticks per Q12 (40 ms/tile @48 MHz) */
	mul	r2, r9
	movh	r9, 0x0024
	orl	r9, 0x9F00		/* 2,400,000 ticks = 50 ms */
	add	r2, r9			/* half period */
	mfsr	r8, COUNT
	ld.w	r9, r7[0x30]
	sub	r9, r8, r9
	cp.w	r9, r2
	brlo	.cph
	st.w	r7[0x30], r8
	ld.w	r9, r7[0x34]
	eor	r9, r1
	st.w	r7[0x34], r9
.cph:
	ld.w	r1, r7[0x34]
.cpo:
	cp.w	r1, 0
	brne	.cpc
	rcall	led_off
	rjmp	.cpd
.cpc:
	cp.w	r0, 0
	breq	.cpr
	rcall	led_green
	rjmp	.cpd
.cpr:
	rcall	led_red
.cpd:
	popm	r0-r7, pc

/* tune(r12 = 0-terminated .word list of note strings): play each, NOTE_MS apart (blocks) */
tune:
	pushm	r0-r7, lr
	mov	r0, r12
.tn:
	ld.w	r12, r0++
	cp.w	r12, 0
	breq	.td
	rcall	emit
	mov	r12, NOTE_MS
	rcall	waitms
	rjmp	.tn
.td:
	popm	r0-r7, pc

/* waitms(r12 = ms) on the COUNT cycle counter; iteration cap so a stopped COUNT can't hang us */
waitms:
	mov	r8, 48000
	mul	r8, r12			/* ticks */
	mov	r10, 12000
	mul	r10, r12		/* cap */
	mfsr	r9, COUNT
.wm:
	mfsr	r11, COUNT
	sub	r11, r9
	cp.w	r11, r8
	brhs	.wd
	sub	r10, 1
	cp.w	r10, 0
	brne	.wm
.wd:
	mov	pc, lr

/* hpoll: re-sample the handpiece (see pongall.s hpoll) -> debounced class @0x20:
   0 idle, 1 CUT, 2 COAG. A class counts only on its 2nd consecutive frame (rejects SPI blips). */
hpoll:
	pushm	r0-r7, lr
	movh	r8, 0x8001
	orl	r8, 0x46b8
	icall	r8			/* 0x800146B8: reload SPI DMA, snapshot, filter */
	mov	r7, 0xF000		/* stock fn clobbers freely */
	mov	r8, 0x29EA
	ld.uh	r9, r8[0]		/* adc(3) = handswitch level */
	mov	r12, 0
	cp.w	r9, 1600
	brlt	.hp_cls
	cp.w	r9, 2600
	brge	.hp_c2
	mov	r12, 1
	rjmp	.hp_cls
.hp_c2:
	cp.w	r9, 2900
	brlt	.hp_cls
	mov	r12, 2
.hp_cls:
	ld.w	r10, r7[0x18]
	st.w	r7[0x18], r12
	cp.w	r10, r12
	breq	.hp_ok
	mov	r12, 0
.hp_ok:
	st.w	r7[0x20], r12
	popm	r0-r7, pc

/* ---- NEM LED + panel primitives, verbatim from pongall.s ---- */
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
/* tunes: .word lists of buzzer commands (bfs<Hz> pitch, beep<ms> play), 0-terminated */
t_pick:	.word	n_e6, n_a6, 0
t_open:	.word	n_g5, n_b5, n_d6, n_g6, 0
t_win:	.word	n_c5, n_e5, n_g5, n_c6, n_e6l, 0
n_c5:	.asciz	"bfs523\rbeep90"
n_e5:	.asciz	"bfs659\rbeep90"
n_g5:	.asciz	"bfs784\rbeep90"
n_b5:	.asciz	"bfs988\rbeep90"
n_c6:	.asciz	"bfs1047\rbeep90"
n_d6:	.asciz	"bfs1175\rbeep90"
n_e6:	.asciz	"bfs1319\rbeep90"
n_g6:	.asciz	"bfs1568\rbeep250"
n_a6:	.asciz	"bfs1760\rbeep160"
n_e6l:	.asciz	"bfs1319\rbeep400"
s_bump:	.asciz	"bfs140\rbeep40"
s_lock:	.asciz	"bfs196\rbeep160"
s_vol:	.asciz	"bvs160"		/* buzzer volume 0-255 (stock alarm 255, chime 50) -- bench knob */
s_m23:	.asciz	"\r\r\rm23"
s_xd:	.asciz	"xd 0 255"
s_mpop:	.asciz	"mpop -1"
s_s1:	.asciz	"s1 0"
s_z:	.asciz	"z"
s_win:	.asciz	"ESCAPED!"
s_hud:	.asciz	"KEYS 0/0"
s_hudopen: .asciz "KEYS 0/0  EXIT OPEN"
	.include "raytab.s"
