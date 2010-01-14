# stones is a game similar to bejeweled.
# the field is a grid of stones.
# two stones can be swapped if that connects three or more stones of the same color either horizontally or vertically.
# those lines of stones are removed, stones above it fall down taking their place, and new random stones are inserted at the top.
# each line increases the score and the time.  when the time bar is filled, the next level is reached.
# the score of a line of n stones in a given level: (2+level)**(n-2)
# so in level 1:  3 stones give 3 points, 4 stones 9, 5 stones 27
# scores are written to /lib/scores/stones.

# todo
# - keep adjusting & drawing time while doing swap/drop animation.  we shouldn't sleep as much in main prog.
# - might have to drop to lowest matches first, then the stones above that.  might be better visually.
# - make clearer when next level is reached
# - mention when new score was reached for score file, make option to show scores
# - tweak score/time formula
# - make less ugly

implement Stones;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
	draw: Draw;
	Rect, Point, Image, Display: import draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "arg.m";
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "rand.m";
	rand: Rand;
include "daytime.m";
	dt: Daytime;
include "util0.m";
	util: Util0;
	min, readfile, writefile, abs, l2a, pid, kill, killgrp, rev, warn: import util;

Stones: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};


dflag: int;
user: string;
map: array of array of int;  # columns or row cells
selected: ref (int, int);
score := 0;
level := 1;
time := 0;  # milliseconds
running := 0;


scorepath: con "/lib/scores/stones";

Timemax: con 30*1000;

Rows: con 10;
Cols: con 10;

Width: con 30;
Height: con 30;

White, Yellow, Orange, Red, Green, Blue, Purple, Colormax: con iota;
Dead: con Colormax;
colors := array[] of {
	Draw->White,
	Draw->Yellow,
	int 16rffb000ff,
	Draw->Red,
	Draw->Green,
	Draw->Blue,
	Draw->Magenta,
	Draw->Black,
};
colorimgs,
colimgs: array of ref Image;
borderimg,
selimg:	ref Image;

tickpid := -1;
tickc: chan of int;
Timewidth: con 280;
Timeheight: con 4;
timerect: con Rect ((0, 0), (Timewidth+2, Timeheight+2));

top: ref Tk->Toplevel;
wmctl: chan of string;
img: ref Image;
timeimg,
fillimg: ref Image;

Score: adt {
	name:	string;
	score:	int;
	level:	int;
	time:	int;
};
scores: array of Score;

tkcmds0 := array[] of {
"frame .ctl",
"button .start -text start -command {send cmd start}",
"label .lscore -text score:",
"label .score",
"pack .start .lscore .score -in .ctl -side left -fill x",

"frame .map",
"panel .p",
"bind .p <ButtonPress> {send cmd down %x %y %b}",
"pack .p -in .map -fill both -expand 1",

"frame .fstatus",
"label .status -text 'x",
"pack .status -in .fstatus -fill x -expand 1 -side left",

"frame .ftime",
"panel .time",
"pack .time -in .ftime -pady 4",

"pack .ctl -fill x",
"pack .map -fill both -expand 1",
"pack .fstatus -fill x",
"pack .ftime -fill x",
};

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	arg := load Arg Arg->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	tkclient->init();
	rand = load Rand Rand->PATH;
	dt = load Daytime Daytime->PATH;
	util = load Util0 Util0->PATH;
	util->init();

	sys->pctl(Sys->NEWPGRP, nil);

	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	if(ctxt == nil)
		fail("no window context");

	seed := sys->millisec();

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-s seed]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
		's' =>	seed = int arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(args != nil)
		arg->usage();

	rand->init(seed);
	scores = scoreread();
	user = readuser();

	(top, wmctl) = tkclient->toplevel(ctxt, "", "stones", Tkclient->Appl);

	tkcmdc := chan of string;
	tk->namechan(top, tkcmdc, "cmd");
	tkcmds(tkcmds0);

	disp := top.display;
	borderimg = disp.color(int 16r808080ff);
	selimg = disp.color(Draw->Black);
	colorimgs = array[len colors] of ref Image;
	for(i := 0; i < len colors; i++)
		colorimgs[i] = disp.color(colors[i]);
	colimgs = array[Cols] of ref Image;
	for(i = 0; i < Cols; i++)
		colimgs[i] = disp.newimage(Rect ((i*Width, 0), ((i+1)*Width, Rows*Height)), disp.image.chans, 0, Draw->White);
	img = disp.newimage(Rect ((0, 0), (Cols*Width, Rows*Height)), disp.image.chans, 0, Draw->White);
	tk->putimage(top, ".p", img, nil);

	timeimg = disp.newimage(timerect, disp.image.chans, 0, Draw->White);
	timeimg.draw(timerect, top.display.white, nil, ZP);
	timeimg.border(timerect, 1, top.display.black, ZP);
	tk->putimage(top, ".time", timeimg, nil);
	fillimg = disp.color(Draw->Red);

	tickc = chan of int;
	setup();

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd"::"ptr"::nil);

	for(;;) alt {
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or s = <-top.wreq =>
		tkclient->wmctl(top, s);
	menu := <-wmctl =>
		case menu {
		"exit" =>
			killgrp(pid());
			return;
		* =>
			tkclient->wmctl(top, menu);
		}

	<-tickc =>
		time -= 90+level*10;
		if(time < 0) {
			for(j := 0; j < len scores; j++)
				if(score > scores[j].score) {
					scores[j+1:] = scores[j:len scores-1];
					scores[j] = (user, score, level, dt->now());
					scorewrite(scores);
					break;
				}
			tkcmd(".status configure -text {game over}; update");
			running = 0;
			if(tickpid >= 0) {
				kill(tickpid);
				tickpid = -1;
			}
		} else
			drawtime();

	cmd := <-tkcmdc=>
		say("cmd, "+cmd);
		t := l2a(str->unquoted(cmd));
		case t[0] {
		"start" =>
			new();
		"down" =>
			if(!running)
				continue;

			x := int t[1];
			y := int t[2];
			pi := x/Width;
			pj := y/Height;
			say(sprint("down, %d,%d", pi, pj));
			if(pi < 0 || pi >= Cols || pj < 0 || pj >= Rows || issel(pi, pj))
				continue;
			nsel := ref (pi, pj);
			if(selected == nil || !adjacent(selected, nsel)) {
				selected = nsel;
				say("new selected");
			} else {
				swap(pi, pj, selected.t0, selected.t1);
				(h0, v0) := expand(pi, pj);
				(h1, v1) := expand(selected.t0, selected.t1);
				if(h0 == nil && v0 == nil && h1 == nil && v1 == nil) {
					swap(pi, pj, selected.t0, selected.t1);
				} else {
					markh(h0);
					markv(v0);
					markh(h1);
					markv(v1);
					flush();
					sys->sleep(100);
					fill();
					mapdraw();

					while(markmatch()) {
						sys->sleep(100);
						fill();
						mapdraw();
					}
				}
				selected = nil;

			drain:
				for(;;) alt {
				<-top.ctxt.ptr =>
					{}
				* =>
					break drain;
				}

			}
			mapdraw();
		* =>
			warn("bogus cmd");
		}
		tkcmd("update");
	}
}

ticker(tickc: chan of int, pidc: chan of int)
{
	pidc <-= pid();
	for(;;) {
		sys->sleep(100);
		tickc <-= 1;
	}
}

setup()
{
	mapgen();
	mapdraw();
	score = 0;
	level = 1;
	drawscore();
	tkcmd(".status configure -text { }; update");
}

start()
{
	time = Timemax/2;
	if(tickpid >= 0)
		kill(tickpid);
	spawn ticker(tickc, pidc := chan of int);
	tickpid = <-pidc;
	drawtime();
	running = 1;
}

new()
{
	if(running)
		setup();
	start();
}

mapgen()
{
	map = array[Rows] of {* => array[Cols] of int};
	for(i := 0; i < Rows; i++)
		for(j := 0; j < Cols; j++)
			do
				map[i][j] = rand->rand(Colormax);
			while(makescombo(i, j));
}

# look through entire map
# turn all matching elems in gray
# return true if at least one matched
markmatch(): int
{
	have := 0;
	for(i := 0; i < Cols; i++)
		for(j := 0; j < Rows; j++) {
			(h, v) := expand(i, j);
			markh(h);
			markv(v);
			if(h != nil)
				say(sprint("markmatch, h %d,%d,%d", h.i, h.j, h.n));
			if(v != nil)
				say(sprint("markmatch, v %d,%d,%d", v.i, v.j, v.n));
			have = have || h != nil || v != nil;
		}
say(sprint("have %d", have));
	return have;
}

fill()
{
	while(fillx())
		{}
}

# fill one row of stones, return false when nothing was filled
fillx(): int
{
	nmatch := 0;
	cols := array[Cols] of {* => (-1, 0)}; # start of match, length

	# find matches, shift downwards, add new random stones from top
Col:
	for(i := 0; i < Cols; i++) {
		for(j := 0; j < Rows; j++) {
			if(map[i][j] != Dead)
				continue;

			nmatch++;
			for(n := 1; j+n < Rows && map[i][j+n] == Dead; n++)
				{}
			map[i][n:] = map[i][:j];
			cols[i] = (j += n, n);
			while(n > 0)
				map[i][--n] = rand->rand(Colormax);
			continue Col;
		}
	}

	# for changed columns, draw new part
	for(i = 0; i < Cols; i++) {
		if(cols[i].t0 < 0)
			continue;

		# fill colimg with new column
		colimg := colimgs[i];
		colimg.draw(colimg.r, top.display.white, nil, ZP);
		for(j := 0; j < cols[i].t0; j++) {
			sr := colimg.r;
			sr.min.y = j*Height;
			sr.max.y = sr.min.y+Height;
			stonedraw0(sr, colorimgs[map[i][j]], colimg);
		}
	}

	# draw all columns, step by step
	for(t := 1;; t++) {
		drawn := 0;
		for(i = 0; i < Cols; i++) {
			if(cols[i].t0 < 0 || t > (tot := cols[i].t1*2))
				continue;

			height := cols[i].t0*Height;
			yscroll := cols[i].t1*Height;
			yoff := yscroll-yscroll*t/tot;

			# make it slide in from the top
			r := img.r;
			r.max.y = height;
			img.draw(r, colimgs[i], nil, Point (0, yoff));

			drawn++;
		}

		if(!drawn)
			break;

		img.flush(Draw->Flushnow);
		tkcmd(".p dirty; update");
		sys->sleep(40);
	}
	return nmatch;
}

scoreplus(n: int)
{
	score += (2+level)**(n-2);
	time += (n-2)*1500;
	if(time > Timemax) {
		level++;
		time = Timemax/2;
	}
	drawtime();
	drawscore();
}

markh(m: ref Match)
{
	if(m == nil)
		return;
	new := 0;
	for(i := 0; i < m.n; i++) {
		nn := map[m.i+i][m.j] != Dead;
		if(nn)
			new++;
		map[m.i+i][m.j] = Dead;
		if(nn)
			stonedrawp(m.i+i, m.j);
	}
	if(new)
		scoreplus(m.n);
}

markv(m: ref Match)
{
	if(m == nil)
		return;
	new := 0;
	for(i := 0; i < m.n; i++) {
		nn := map[m.i][m.j+i] != Dead;
		if(nn)
			new++;
		map[m.i][m.j+i] = Dead;
		if(nn)
			stonedrawp(m.i, m.j+i);
	}
	if(new)
		scoreplus(m.n);
}

tkdirty(r: Rect)
{
	tkcmd(sprint(".p dirty %d %d %d %d", r.min.x, r.min.y, r.max.x, r.max.y));
}

swap(i0, j0, i1, j1: int)
{
	p0 := Point (i0*Width, j0*Height);
	p1 := Point (i1*Width, j1*Height);
	r0 := Rect (p0, p0.add(Point (Width, Height)));
	r1 := Rect (p1, p1.add(Point (Width, Height)));
	delta := r1.min.sub(r0.min);
	Frames: con 5;
	for(f := 0; f < Frames; f++) {
		d := Point (delta.x*(1+f)/Frames, delta.y*(1+f)/10);
		x0 := r0.addpt(d);
		x1 := r1.subpt(d);
		deadimg := colorimgs[Dead];
		img.draw(r0, deadimg, nil, ZP);
		img.draw(r1, deadimg, nil, ZP);
		tkdirty(r0);
		tkdirty(r1);
		stonedraw(x0, colorimgs[map[i0][j0]]);
		stonedraw(x1, colorimgs[map[i1][j1]]);
		img.flush(Draw->Flushnow);
		tkcmd("update");
		sys->sleep(40);
	}

	t := map[i0][j0];
	map[i0][j0] = map[i1][j1];
	map[i1][j1] = t;

	# make sure white bg comes back
	img.draw(r0, top.display.white, nil, ZP);
	img.draw(r1, top.display.white, nil, ZP);
	img.flush(Draw->Flushnow);
	stonedraw(r0, colorimgs[map[i0][j0]]);
	stonedraw(r1, colorimgs[map[i1][j1]]);
	tkdirty(r0);
	tkdirty(r1);
	tkcmd("update");
}

stonedrawp(i, j: int)
{
	x := i*Width;
	y := j*Height;
	r := Rect ((x, y), (x+Width, y+Height));
	stonedraw(r, colorimgs[map[i][j]]);
}

stonedraw0(r: Rect, i, where: ref Image)
{
	off := Point (1, 1);
	r = Rect (r.min.add(off), r.max.sub(off));
	where.draw(r, i, nil, ZP);
	bimg := borderimg;
	width := 1;
	where.border(r, width, bimg, ZP);
}

stonedraw(r: Rect, i: ref Image)
{
	stonedraw0(r, i, img);
	tkdirty(r);
}

Match: adt {
	i, j,
	n:	int;
};

expand(i, j: int): (ref Match, ref Match)
{
	t := map[i][j];
	if(t == Dead)
		return (nil, nil);

	h := ref Match (i, j, 0);
	while(h.i > 0 && map[h.i-1][j] == t)
		h.i--;
	h.n = i-h.i+1;
	while((o := h.i+h.n) < Cols && map[o][j] == t)
		h.n++;

	v := ref Match (i, j, 0);
	while(v.j > 0 && map[i][v.j-1] == t)
		v.j--;
	v.n = j-v.j+1;
	while((o = v.j+v.n) < Rows && map[i][o] == t)
		v.n++;

	if(h.n < 3)
		h = nil;
	if(v.n < 3)
		v = nil;
	return (h, v);
}

adjacent(a, b: ref (int, int)): int
{
	di := abs(a.t0-b.t0);
	dj := abs(a.t1-b.t1);
	return di == 1 && dj == 0 || di == 0 && dj == 1;
}

issel(i, j: int): int
{
	r := selected != nil && selected.t0 == i && selected.t1 == j;
	return r;
}

# whether elem at i,j makes combo with blocks to left or up
makescombo(i, j: int): int
{
	v := map[i][j];
	return i >= 2 && map[i-1][j] == v && map[i-2][j] == v || j >= 2 && map[i][j-1] == v && map[i][j-2] == v;
}

ZP: con Point (0, 0);
mapdraw()
{
	for(i := 0; i < Rows; i++)
		for(j := 0; j < Cols; j++) {
			x := i*Width;
			y := j*Height;
			r := Rect((x+1, y+1), (x+Width-1, y+Height-1));
			img.draw(r, colorimgs[map[i][j]], nil, ZP);
			bimg := borderimg;
			width := 1;
			if(issel(i, j)) {
				bimg = selimg;
				say("selected");
			}
			img.border(r, width, bimg, ZP);
		}
	tkcmd(".p dirty");
}

flush()
{
	img.flush(Draw->Flushnow);
	tkcmd(".p dirty; update");
}

drawscore()
{
	tkcmd(sprint(".score configure -text {level %d, score %d}; update", level, score));
}

drawtime()
{
	x := 1+min(Timewidth, Timewidth*time/Timemax);
	r0 := Rect ((1, 1), (x, 1+Timeheight));
	r1 := Rect ((x, 1), (Timewidth-1, 1+Timeheight));
	timeimg.draw(r0, fillimg, nil, ZP);
	timeimg.draw(r1, top.display.white, nil, ZP);
	timeimg.flush(Draw->Flushnow);
	tkcmd(".time dirty");
	tkcmd("update");
}


scoreread(): array of Score
{
	f := scorepath;
	b := bufio->open(f, Bufio->OREAD);
	if(b == nil)
		fail(sprint("reading %q: %r", f));
	sc := array[10] of {* => Score ("none", 0, 0, 0)};
	nr := 0;
	for(;;) {
		s := b.gets('\n');
		if(s == nil || nr >= len sc)
			break;
		t := l2a(str->unquoted(s));
		if(len t != 4)
			fail(sprint("bad score file %q, line %d", f, nr+1));
		sc[nr++] = Score (t[0], int t[1], int t[2], dt->now());
	}
	return sc;
}

scorewrite(s: array of Score)
{
	if(len s != 10)
		raise "not 10 scores?";
	f := scorepath;
	b := bufio->create(f, Bufio->OWRITE, 8r666);
	if(b == nil)
		fail(sprint("create %q: %r", f));
	for(i := 0; i < len s; i++) {
		ss := s[i];
		b.puts(sprint("%q %d %d %d\n", ss.name, ss.score, ss.level, ss.time));
	}
	if(b.flush() == Bufio->ERROR)
		fail(sprint("writing %q: %r", f));
}


readuser(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	n := sys->read(fd, buf := array[1024] of byte, len buf);
	if(n <= 0)
		return "none";
	return string buf[:n];
}

tkcmd(s: string): string
{
	r := tk->cmd(top, s);
	if(r != nil && r[0] == '!')
		warn(sprint("tkcmd: %q: %s", s, r));
	return r;
}

tkcmds(a: array of string)
{
	for(i := 0; i < len a; i++)
		tkcmd(a[i]);
}

say(s: string)
{
	if(dflag)
		warn(s);
}

fail(s: string)
{
	warn(s);
	killgrp(pid());
	raise "fail:"+s;
}
