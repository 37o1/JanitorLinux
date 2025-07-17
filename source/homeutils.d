module homeutils;

string getHomeDir() {
	import std.process : environment;
	version (Windows) {
		return environment["USERPROFILE"];
	} else version (Posix) {
		return environment["HOME"];
	} else {
		assert(0, "Platform not supported!");
	}
}
