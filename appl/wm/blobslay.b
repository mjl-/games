implement BlobSlay;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
	draw: Draw;
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
	readfile, writefile, pid, killgrp, rev, warn: import util;

t: ref Tk->Toplevel;
wmctl: chan of string;

BlobSlay: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

highpath: con "/lib/scores/blobslay";
Red, Blue, Green, Yellow, Purple, Empty, Colormax: con iota;
colors := array[] of {"red", "blue", "green", "yellow", "purple", "gray"};
colorchars := array[] of {"r", "b", "g", "y", "p", " "};
Width: con 11;
Height: con 8;

selmap, startmap, map, prevmap: array of array of int;
nsel := 0;
score := 0;
prevscore := 0;
high := 0;
done := 0;
actions: list of ref (int, int);

tkcmds0 := array[] of {
"frame .ctl",
"button .new -text new -command {send cmd new}",
"button .undo -text undo -command {send cmd undo}",
"button .restart -text restart -command {send cmd restart}",
"button .save -text save -command {send cmd save}",
"pack .new .undo .restart .save -in .ctl -side left -fill x",

"frame .map",
};

tkcmds1 := array[] of {
"label .game -text select...",
"frame .score",
"label .scoredescr -text {score: }",
"label .total -text 0",
"label .seldescr -text {selection: }",
"label .sel -text 0",
"label .highdescr -text {high: }",
"label .high -text 0",
"pack .scoredescr .total .seldescr .sel .highdescr .high -in .score -side left -fill x",

"pack .ctl -fill x",
"pack .map -side top -fill both -expand 1",
"pack .game .score -side top -fill x",
"pack propagate . 0",
};

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
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
	arg->setusage(arg->progname()+" [-s seed]");
	while((c := arg->opt()) != 0)
		case c {
		's' =>	seed = int arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(args != nil)
		arg->usage();

	(t, wmctl) = tkclient->toplevel(ctxt, "", "blobslay", Tkclient->Appl);

	tkcmdchan := chan of string;
	tk->namechan(t, tkcmdchan, "cmd");
	tkcmds(tkcmds0);
	tkmap();
	tkcmds(tkcmds1);

	rand->init(seed);
	high = highread();
	emptysel();
	genmap();
	drawmap();

	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd"::"ptr"::nil);

	for(;;) alt {
	s := <-t.ctxt.kbd =>
		tk->keyboard(t, s);
	s := <-t.ctxt.ptr =>
		tk->pointer(t, *s);
	s := <-t.ctxt.ctl or s = <-t.wreq =>
		tkclient->wmctl(t, s);
	menu := <-wmctl =>
		case menu {
		"exit" =>
			killgrp(pid());
			return;
		* =>
			tkclient->wmctl(t, menu);
		}

	cmd := <-tkcmdchan =>
		l := str->unquoted(cmd);
		which := hd l;
		l = tl l;
		case which {
		"new" =>
			actions = nil;
			score = 0;
			done = 0;
			emptysel();
			genmap();
			drawmap();
			tkgame("select...");
		"undo" =>
			if(done || prevmap == nil) {
				tkgame("no more undo...");
			} else {
				actions = tl actions;
				map = prevmap;
				prevmap = nil;
				score = prevscore;
				emptysel();
				drawmap();
				tkgame("reverted...");
			}
		"restart" =>
			actions = nil;
			score = 0;
			done = 0;
			emptysel();
			map = startmap;
			drawmap();
			tkgame("restarted...");
		"save" =>
			path := sprint("/tmp/blobslay-%d", dt->now());
			err := save(path);
			if(err != nil)
				tkgame(sprint("saving %q: %s", path, err));
			else
				tkgame(sprint("saved as %q", path));
		"blob" =>
			x := int hd l;
			y := int hd tl l;
			if(selmap[x][y]) {
				delete();
				actions = ref (x, y)::actions;
			} else
				select(x, y);
			drawmap();
		* =>
			warn(sprint("unknown command: %q", cmd));
		}
		tkcmd("update");
	}
}

emptysel()
{
	selmap = array[Width] of {* => array[Height] of {* => 0}};
	nsel = 0;
}

isdone(): int
{
	for(i := 0; i < len map; i++)
		for(j := 0; j < len map[0]; j++) {
			opts := array[] of {(i+1,j), (i-1,j), (i,j+1), (i,j-1)};
			for(k := 0; k < len opts; k++) {
				(ni, nj) := opts[k];
				if(ni >= 0 && nj >= 0 && ni < len map && nj < len map[0] && map[i][j] != Empty && map[i][j] == map[ni][nj])
					return 0;
			}
		}
	return 1;
}

copymap()
{
	prevmap = map;
	map = array[Width] of {* => array[Height] of int};
	for(i := 0; i < len map; i++)
		for(j := 0; j < len map[i]; j++)
			map[i][j] = prevmap[i][j];
}

delete()
{
	copymap();

	prevscore = score;
	score += nsel*(nsel-1);

	# 1. mark selected elements as empty
	for(i := 0; i < len map; i++)
		for(j := 0; j < len map[i]; j++)
			if(selmap[i][j])
				map[i][j] = Empty;

	# 2. compact empty elements
	for(i = 0; i < len map; i++) {
		j = 0;
		for(n := 0; n < len map[i]; n++)
			if(map[i][j] == Empty) {
				map[i][j:] = map[i][j+1:];
				map[i][len map[i]-1] = Empty;
			} else
				j++;
	}

	# 3. remove empty columns
	i = 0;
	for(n := 0; n < len map; n++)
		if(map[i][0] == Empty) {
			map[i:] = map[i+1:];
			map[len map-1] = array[len map[0]] of {* => Empty};
		} else
			i++;

	emptysel();
	if(done = isdone()) {
		if(score > high) {
			high = score;
			err := highwrite(high);
			if(err != nil)
				tkgame(sprint("new highscore, %d;  saving failed: %s", high, err));
			tkgame(sprint("new highscore, %d!", high));
		} else
			tkgame(sprint("no highscore, %d points short...", high-score));
	} else
		tkgame("select...");
}

select(x, y: int)
{
	emptysel();
	selmap[x][y] = 1;
	nsel = 1;
	mark(x, y);
	if(nsel < 2) {
		selmap[x][y] = 0;
		nsel = 0;
	}
}

mark(x, y: int)
{
	opts := array[] of {(x+1,y), (x-1,y), (x,y+1), (x,y-1)};
	for(i := 0; i < len opts; i++) {
		(nx, ny) := opts[i];
		if(nx >= 0 && ny >= 0 && nx < len selmap && ny < len selmap[0] && map[x][y] != Empty && !selmap[nx][ny] && map[x][y] == map[nx][ny]) {
			selmap[nx][ny] = 1;
			nsel++;
			mark(nx, ny);
		}
	}
}

highread(): int
{
	return int string readfile(highpath, 128);
}

highwrite(s: int): string
{
	return writefile(highpath, 1, array of byte string s);
}

save(path: string): string
{
	s := "";
	for(i := len startmap[0]-1; i >= 0; i--) {
		for(j := len startmap-1; j >= 0; j--)
			s += sprint("%s", colorchars[startmap[j][i]]);
		s += "\n";
	}
	for(l := rev(actions); l != nil; l = tl l)
		s += sprint("%d %d\n", (hd l).t0, (hd l).t1);
	return writefile(path, 1, array of byte s);
}

tkgame(s: string)
{
	tkcmd(sprint(".game configure -text '%s", s));
}

tkscore()
{
	sel := 0;
	if(nsel > 0)
		sel = nsel*(nsel-1);
	tkcmd(sprint(".total configure -text {%3d}", score));
	tkcmd(sprint(".sel configure -text {%3d}", sel));
	tkcmd(sprint(".high configure -text {%3d}", high));
}

tkmap()
{
	for(i := 0; i < Width; i++) {
		tkcmd(sprint("frame .col%d", i));
		for(j := 0; j < Height; j++) {
			tkcmd(sprint("button .b.%d.%d -width 25 -height 25 -command {send cmd blob %d %d}", i, j, i, j));
			tkcmd(sprint("pack .b.%d.%d -in .col%d -side bottom -fill both -expand 1", i, j, i));
		}
		tkcmd(sprint("pack .col%d -in .map -side right -fill both -expand 1", i));
	}
}

genmap()
{
	startmap = map = array[Width] of {* => array[Height] of int};
	for(i := 0; i < len map; i++)
		for(j := 0; j < len map[0]; j++)
			map[i][j] = rand->rand(Empty);
}

drawmap()
{
	for(i := 0; i < len map; i++)
		for(j := 0; j < len map[i]; j++) {
			fore := "black";
			if(selmap[i][j])
				fore = "white";
			if(done)
				fore = "gray";
			colorchar := colorchars[map[i][j]];
			back := colors[map[i][j]];
			tkcmd(sprint(".b.%d.%d configure -text {%s} -activeforeground %s -foreground %s -activebackground %s -background %s", i, j, colorchar, fore, fore, back, back));
		}
	tkscore();
}

tkcmd(s: string): string
{
	r := tk->cmd(t, s);
	if(r != nil && r[0] == '!')
		warn(sprint("tkcmd: %q: %s", s, r));
	return r;
}

tkcmds(a: array of string)
{
	for(i := 0; i < len a; i++)
		tkcmd(a[i]);
}

fail(s: string)
{
	warn(s);
	killgrp(pid());
	raise "fail:"+s;
}
