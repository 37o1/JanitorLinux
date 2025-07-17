import std.stdio;
import homeutils;
import std.uuid;
import std.file;
import std.string;
import std.string : split;
import std.typecons;
import std.process;
import core.sync.mutex;
import std.conv;
import core.time;
import std.datetime;
import core.thread;
import std.concurrency;
import std.traits;
import std.algorithm;
import std.array;
import std.math;
import raylib;

class Events(CB, Args = Parameters!CB) if (is(CB == delegate)) {
	private shared Mutex mtx;
	private CB[][string] listeners;
	private bool _terminate = false;
	public void terminate () shared {
		this._terminate = true;
	}

	static this() {}
	this () {
		this.mtx = new shared Mutex();
	}

	public void on(L)(string key, L l) {
		if (isCallable!L && isDelegate!L) {
			synchronized(mtx) {
				if (!(key in listeners)) listeners[key] = [];
				listeners[key] ~= cast(CB)l;
			}
		}
	}

	public void emit(string key, Args args) {
		if (this._terminate) return;
		CB[] dgs;
		synchronized(mtx) {
			dgs = listeners.get(key, []);
		}
		foreach (l; dgs) {
			auto t = new Thread({ l(args); });
			t.start();
		}
	}
}

/// returns a set of file sizes keyed by their absolute path
import std.stdio;
import std.datetime;
import std.file;
import std.algorithm;
import std.typecons;
import std.array;

Tuple!(string, ulong, ulong)[] findAllFileSizes(string root) {
	Tuple!(ulong, ulong)[string] cur;

	foreach (string node; dirEntries(root, SpanMode.depth)) {
		if (isFile(node)) {
			Duration age = Clock.currTime() - timeLastModified(node);
			cur[node] = tuple(getSize(node), age.total!"seconds");
		}
	}
	// flatten to a tuple of (string, size, age)
	auto a = cur.byKeyValue
		.map!(e => tuple(e.key, e.value[0], e.value[1]))
		.array;

	// sort by age (3rd element) descending
	sort!((a, b) => a[2] > b[2])(a);

	return a;
}


class Tracked {
	/// Static list holding loaded tracked dirs
	static shared Tracked[] list;
	/// Global on/off
	static bool enabled;
	Events!(void delegate()) events;

	static this () {
		Tracked.enabled = true;
	}

	immutable UUID id;
	/// Must be an absolute path to the directy 
	string location;
	bool active;
	/// The maximum size of the directory in Bytes
	ulong cap;
	/// The maximum lifetime of a to-be-deleted file in seconds
	ulong lifetime;

	/// For loading existing items
	this (string path) {
		Tracked.list ~= cast(shared)this;
		this.events = new Events!(void delegate());
		string raw = readText(path);
		string[] arg = split(raw, separator);
		this.id = UUID(split(path, '/')[$ - 1]);
		this.location = arg[0];
		writeln(arg, arg[0]);
		this.active = cast(bool)cast(ubyte)((cast(char[])arg[1])[0] - 0x30);
		this.cap = to!ulong(arg[2]);
		this.lifetime = to!ulong(arg[3]);
		writeln("Successfuly loaded entry: ", this.location, Tracked.list);

		this.events.on("track", delegate(){
			if (this.active && Tracked.enabled) { try {
				writeln("Track: " ~ this.location);
				Tuple!(string, ulong, ulong)[] sizes = findAllFileSizes(this.location);
				ulong size = 0;
				foreach (Tuple!(string, ulong, ulong) key; sizes) {
					if (key[2] > this.lifetime) {
						writeln(location, " TRASH ", key[0]);
						moveToTrash(key[0]);
						return this.events.emit("track");
					}
					size += key[1];
				}
				long dif = cast(long)this.cap - cast(long)size;
				if (dif < 0) {
					// dir exceeds max size, del oldest file
					writeln(location, " TRASH ", sizes[0][0]);
					moveToTrash(sizes[0][0]);
					return this.events.emit("track");
				}
			}catch(Throwable e){}}
			Thread.sleep(10.seconds);
			this.events.emit("track");
		});
		this.events.emit("track");
	}

	/// For creating new tracked items
	this () {
		this.id = randomUUID();
	}

	string toString() shared const pure {
		return this.location
		~ separator ~ cast(char)(cast(ubyte)this.active + 0x30) // make it into a string representation of 0 or 1
		~ separator ~ to!string(this.cap)
		~ separator ~ to!string(this.lifetime);
	}		bool[int] writeKC;


	void save () shared {
		mkdirRecurse(getHomeDir() ~ "/.janitor/entries");
		File file = File(getHomeDir() ~ "/.janitor/entries/" ~ this.id.toString(), "w");
		file.write(this.toString());
		file.close();
	}
}

static immutable char separator = cast (char) 0x1F;

void moveToTrash(string path) {
	auto result = execute(["gio", "trash", path]);
	if (result.status != 0) {
		stderr.writeln("Failed to move to trash: ", result.output);
	}
}

void main() {
	// write something to the screen to show it works at least
	mkdirRecurse(getHomeDir() ~ "/.janitor/entries");
	writeln("Loading config from: " ~ getHomeDir() ~ "/.janitor");
	
	Events!(void delegate(Tracked)) eventLoop = new Events!(void delegate(Tracked));

	eventLoop.on("reload", delegate(Tracked _dummy){
		foreach (shared Tracked tracked; Tracked.list) {
			tracked.events.terminate();
		}
		Tracked.list = [];
		foreach (string entry; dirEntries(getHomeDir() ~ "/.janitor/entries", SpanMode.shallow)) {
			writeln("Loading entry: ", entry);
			new Tracked(entry);
		}
	});

	if (!exists(getHomeDir() ~ "/.janitor/enabled")) {
		File file = File(getHomeDir() ~ "/.janitor/enabled", "w");
		file.write(cast(string)(cast(char[])[0x31]));
		file.close();
	}
	Tracked.enabled = cast(bool)(cast(ubyte)(cast(char)(readText(getHomeDir() ~ "/.janitor/enabled")[0])) - 0x30);
	writeln("Tracked.enabled: ", Tracked.enabled);

	new Thread((){
		eventLoop.emit("reload", new Tracked);
		int selectedX = 0;
		int selectedY = 0;


		bool bsC;
		int writeP;

		void handleWriting () {
			if (IsKeyDown(KeyboardKey.KEY_BACKSPACE) && !bsC) {
				if (Tracked.list[selectedY].location.length > 0) {
					Tracked.list[selectedY].location = Tracked.list[selectedY].location[0 .. $ - 1];
					Tracked.list[selectedY].save();
				}
			} else if (
				!IsKeyDown(KeyboardKey.KEY_LEFT) &&
				!IsKeyDown(KeyboardKey.KEY_RIGHT) &&
				!IsKeyDown(KeyboardKey.KEY_UP) &&
				!IsKeyDown(KeyboardKey.KEY_DOWN)
			) {
				int ch = GetCharPressed();
				if (ch != 0) {
					Tracked.list[selectedY].location ~= cast (string) cast (char[]) [ch];
					Tracked.list[selectedY].save();
				}
			}
			writeP = GetCharPressed();
			bsC = IsKeyDown(KeyboardKey.KEY_BACKSPACE);
		}

		InitWindow(0,0, "Janitor");
		SetTargetFPS(60);

		bool[KeyboardKey] keycache;
		while (!WindowShouldClose()){
			selectedY = max(0, min((Tracked.list.length) - 1, selectedY));
			BeginDrawing();
			int maxwidth = 32;
			ClearBackground(Color(32, 32, 32));
			int i = 0;
			foreach (shared Tracked entry; Tracked.list) {
				int capScale = 0;
				double capScaled = cast(double)entry.cap;
				while (capScaled >= 1024) {
					capScaled = capScaled / cast(double)1024;
					capScale++;
				}
				auto readableCap = toStringz(to!string(capScaled) ~ scales[capScale]);
				int timeScale = 0;
				double timeScaled = cast(double)entry.lifetime;
				while (timeScaled >= tfscales[timeScale]) {
					timeScaled = timeScaled / tfscales[timeScale];
					timeScale++;
				}
				string tsts = to!string(timeScaled);
				auto readableTime = (split(tsts, '.').length > 1)
					? toStringz(split(tsts, '.')[0] ~ '.' ~ split(tsts, '.')[1][0] ~ tscales[timeScale])
					: toStringz(to!string(timeScaled) ~ tscales[timeScale]);
				int y = 16 + i * 32;
				immutable(char)* readableLoc1;
				immutable(char)* readableLoc2;
				if (array(split(entry.location, '/')).length < 2) {
					readableLoc1 = toStringz(entry.location);
					readableLoc2 = toStringz("");
				} else {
					readableLoc1 = toStringz(join(split(entry.location, '/')[0 .. $ - 1], '/') ~ "/");
					readableLoc2 = toStringz((split(entry.location, '/')[$ - 1]));
				}
				DrawText(readableLoc1, 16, y, 32, Color(128, 128, 128));
				DrawText(readableLoc2, 16 + MeasureText(readableLoc1, 32) + 4, y, 32, Color(255, 255, 255));
				int x = MeasureText(toStringz(entry.location), 32) + 32;
				DrawText(toStringz(entry.active ? "ON" : "OFF"), x, y, 32, Color(entry.active ? 0 : 255, entry.active ? 255 : 0, 0));
				x += MeasureText(toStringz(entry.active ? "ON" : "OFF"), 32) + 16;
				DrawText(readableCap, x, y, 32, Color(255,128,255));
				x += MeasureText(readableCap, 32) + 16;
				DrawText(readableTime, x, y, 32, Color(128,255,255));
				x += MeasureText(readableTime, 32) + 16;

				if (selectedY == i) {
					if (selectedX == 0) {
						DrawLine(16, y, MeasureText(toStringz(entry.location), 32) + 16, y, Color(255, 0, 255));
						DrawLine(16, y + 32, MeasureText(toStringz(entry.location), 32) + 16, y + 32, Color(255, 0, 255));
					}
					if (selectedX == 1) {
						DrawLine(
							MeasureText(toStringz(entry.location), 32)
								+ 32,
							y,
							MeasureText(toStringz(entry.location), 32)
								+ 16
								+ MeasureText(toStringz(entry.active ? "ON" : "OFF"), 32)
								+ 16,
							y,
							Color(255, 0, 255)
						);
						DrawLine(
							MeasureText(toStringz(entry.location), 32)
								+ 32,
							y + 32,
							MeasureText(toStringz(entry.location), 32) + 16
							+ MeasureText(toStringz(entry.active ? "ON" : "OFF"), 32) + 16,
							y + 32,
							Color(255, 0, 255)
						);
					}
					if (selectedX == 2) {
						DrawLine(
							MeasureText(toStringz(entry.location), 32) + 32
							+ MeasureText(toStringz(entry.active ? "ON" : "OFF"), 32) + 16,
							y,
							MeasureText(toStringz(entry.location), 32) + 16
							+ MeasureText(toStringz(entry.active ? "ON" : "OFF"), 32) + 16
							+ MeasureText(readableCap, 32) + 16,
							y,
							Color(255, 0, 255)
						);
						DrawLine(
							MeasureText(toStringz(entry.location), 32) + 32
							+ MeasureText(toStringz(entry.active ? "ON" : "OFF"), 32) + 16,
							y + 32,
							MeasureText(toStringz(entry.location), 32) + 16
							+ MeasureText(toStringz(entry.active ? "ON" : "OFF"), 32) + 16
							+ MeasureText(readableCap, 32) + 16,
							y + 32,
							Color(255, 0, 255)
						);
					}
					if (selectedX == 3) {
						DrawLine(
							MeasureText(toStringz(entry.location), 32) + 32
							+ MeasureText(toStringz(entry.active ? "ON" : "OFF"), 32) + 32
							+ MeasureText(readableTime, 32) + 16,
							y,
							MeasureText(toStringz(entry.location), 32) + 16
							+ MeasureText(toStringz(entry.active ? "ON" : "OFF"), 32) + 16
							+ MeasureText(readableCap, 32) + 16
							+ MeasureText(readableTime, 32) + 16,
							y,
							Color(255, 0, 255)
						);
						DrawLine(
							MeasureText(toStringz(entry.location), 32) + 32
							+ MeasureText(toStringz(entry.active ? "ON" : "OFF"), 32) + 32
							+ MeasureText(readableTime, 32) + 16,
							y + 32,
							MeasureText(toStringz(entry.location), 32) + 16
							+ MeasureText(toStringz(entry.active ? "ON" : "OFF"), 32) + 16
							+ MeasureText(readableCap, 32) + 16
							+ MeasureText(readableTime, 32) + 16,
							y + 32,
							Color(255, 0, 255)
						);
					}
				}
				maxwidth = max(maxwidth, x);
				i++;
			}
			//DrawFPS(0, 0);
			EndDrawing();
			SetWindowSize(maxwidth, max(cast(int)Tracked.list.length * 32 + 32, i * 32 + 32));

			if (IsKeyDown(KeyboardKey.KEY_RIGHT) && !keycache[KeyboardKey.KEY_RIGHT]) {
				selectedX++;
				if(selectedX >= 4) selectedX = 0;
			}
			if (IsKeyDown(KeyboardKey.KEY_LEFT) && !keycache[KeyboardKey.KEY_LEFT]) {
				selectedX--;
				if(selectedX < 0) selectedX = 3;
			}
			if (selectedX == 0) {
				handleWriting();
			} else {
				if (IsKeyDown(KeyboardKey.KEY_UP)) {
					if (IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT)) {
						if (selectedX == 1) {
							Tracked.list[selectedY].active = true;
							Tracked.list[selectedY].save();
						}
						if (selectedX == 2) {
							int capScale = 0;
							double capScaled = cast(double)Tracked.list[selectedY].cap;
							while (capScaled >= 1024) {
								capScaled = capScaled / cast(double)1024;
								capScale++;
							}
							ulong c = cast(ulong)Tracked.list[selectedY].cap;
							c += pow(1024, capScale);
							c = min(1020000000000, max(1, c));
							Tracked.list[selectedY].cap = c;
							Tracked.list[selectedY].save();
						}
						if (selectedX == 3) {
							int timeScale = 0;
							double timeScaled = cast(double)Tracked.list[selectedY].lifetime;
							while (timeScaled >= tfscales[timeScale]) {
								timeScaled = timeScaled / tfscales[timeScale];
								timeScale++;
							}
							ulong c = cast(ulong)Tracked.list[selectedY].lifetime;
							c += cast(ulong)(c / tfscales[timeScale]);
							c = min(31000000000, max(c, 60));
							Tracked.list[selectedY].lifetime = c;
							Tracked.list[selectedY].save();
						}
					} else if (!keycache[KeyboardKey.KEY_UP]) {
						selectedY--;
						if(selectedY < 0) selectedY = cast(int)Tracked.list.length - 1;
					}
				}
				if (IsKeyDown(KeyboardKey.KEY_DOWN)) {
					if (IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT)) {
						if (selectedX == 1) {
							Tracked.list[selectedY].active = false;
							Tracked.list[selectedY].save();
						}
						if (selectedX == 2) {
							int capScale = 0;
							double capScaled = cast(double)Tracked.list[selectedY].cap;
							while (capScaled >= 1024) {
								capScaled = capScaled / cast(double)1024;
								capScale++;
								// better decremenent scaling
								if (capScaled == 1) capScale--;
							}
							ulong c = cast(ulong)Tracked.list[selectedY].cap;
							c -= pow(1024, capScale);
							c = min(1020000000000, max(1, c));
							Tracked.list[selectedY].cap = c;
							Tracked.list[selectedY].save();
						}
						if (selectedX == 3) {
							int timeScale = 0;
							double timeScaled = cast(double)Tracked.list[selectedY].lifetime;
							while (timeScaled >= tfscales[timeScale]) {
								timeScaled = timeScaled / tfscales[timeScale];
								timeScale++;
							}
							ulong c = cast(ulong)Tracked.list[selectedY].lifetime;
							c -= cast(ulong)(c / tfscales[timeScale]);
							c = min(31000000000, max(c, 60));
							Tracked.list[selectedY].lifetime = c;
							Tracked.list[selectedY].save();
						}
					} else if (!keycache[KeyboardKey.KEY_DOWN]) {
						selectedY++;
						if(selectedY >= Tracked.list.length) selectedY = 0;
					}
				}
				if (IsKeyDown(KeyboardKey.KEY_LEFT_ALT) && IsKeyDown(KeyboardKey.KEY_A) && !keycache[KeyboardKey.KEY_A]) {
					shared Tracked tracked = cast (shared) new Tracked();
					tracked.location = "/location";
					tracked.active = false;
					tracked.cap = 1024 * 1024;
					tracked.lifetime = 3600 * 7;
					tracked.save();
					eventLoop.emit("reload", cast(Tracked) tracked);
				}
				if (IsKeyDown(KeyboardKey.KEY_DELETE) && !keycache[KeyboardKey.KEY_DELETE]) {
					moveToTrash(getHomeDir() ~ "/.janitor/entries/" ~ Tracked.list[selectedY].id.toString());
					eventLoop.emit("reload", new Tracked());
				}
			}
			keycache[KeyboardKey.KEY_RIGHT] = IsKeyDown(KeyboardKey.KEY_RIGHT);
			keycache[KeyboardKey.KEY_LEFT] = IsKeyDown(KeyboardKey.KEY_LEFT);
			keycache[KeyboardKey.KEY_UP] = IsKeyDown(KeyboardKey.KEY_UP);
			keycache[KeyboardKey.KEY_DOWN] = IsKeyDown(KeyboardKey.KEY_DOWN);
			keycache[KeyboardKey.KEY_A] = IsKeyDown(KeyboardKey.KEY_A);
			keycache[KeyboardKey.KEY_DELETE] = IsKeyDown(KeyboardKey.KEY_DELETE);
		}

		CloseWindow();
		foreach (shared Tracked tracked; Tracked.list) {
			tracked.events.terminate();
		}
		Tracked.list = [];
		writeln("Closing! May take longer to stop all running threads, please be patient...");
		// all running code stops at this point, D makes sure the process will exit
	}).start();
}


static string[] scales = ["B", "kB", "MB", "GB", "TB", "PT", "EB", "ZB", "YT"];
static string[] tscales = ["s", "m", "h", "d", "mon", "y", "dec", "cen", "kyr"];
static double[] tfscales = [60, 60, 24, 30.436875, 12, 10, 10, 10, 10];
