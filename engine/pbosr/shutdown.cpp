#pragma warning(disable : 4996)

#include "app.h"

namespace fs = std::filesystem;
using namespace std;

using convert_t = codecvt_utf8<wchar_t>;
wstring_convert<convert_t, wchar_t> strconverter;

// Shared-folder root mounted from the Linux host. All transit data and logs
// live here so the host (and any admin) can see what happened on the
// shutdown side.
static const string SHARED = "\\\\VBoxSvr\\dest";
static const string LOG_PATH = SHARED + "\\shutdown.log";

void generate_whitelist();
void parse_users();
void parse_whitelist();
void verify_canaries();
bool SHCopy(LPCTSTR from, LPCTSTR to, int& errCode, bool& anyAborted);
wstring to_wstring(string str);
string current_timestamp();
void log_line(const string& msg);

// Canary file conventions — must match Boot.exe.
static const string CANARY_FILENAME = "osr-canary.txt";
static const string CANARY_MAGIC = "OSR_CANARY_v1";

int main() {
	log_line("=== Shutdown.exe begin ===");
	parse_users();
	generate_whitelist();
	verify_canaries();
	parse_whitelist();

	remove("users.txt");
	remove("whitelist.txt");

	// Drop a sentinel the host can check after Dirty-2 powers off. host.sh
	// logs a warning if this is missing, indicating Shutdown.exe did not
	// run to completion (e.g. crashed, or Windows killed it past the
	// shutdown-script grace period).
	{
		ofstream sentinel(SHARED + "\\shutdown-complete.flag");
		if (sentinel.is_open()) {
			sentinel << current_timestamp() << "\n";
		}
	}

	log_line("=== Shutdown.exe complete; issuing system shutdown ===");
	system("C:\\Windows\\System32\\shutdown.exe /s /t 0 /d p:0:0 /c \"Proactive Backup\"");
}

string current_timestamp() {
	time_t t = time(nullptr);
	char buf[32];
	struct tm tmv;
	localtime_s(&tmv, &t);
	strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tmv);
	return string(buf);
}

void log_line(const string& msg) {
	// Append to the shared-folder log so the Linux host has visibility.
	// Open/close per call so partial work survives a crash mid-run.
	ofstream lf(LOG_PATH, ios::app);
	if (lf.is_open()) {
		lf << current_timestamp() << "  " << msg << "\n";
	}
	cout << msg << endl;
}

// Walk whitelist.txt and verify that each whitelisted directory still
// contains an osr-canary.txt with the expected magic header. Boot.exe
// dropped these in after restoring user files; if any are missing or
// modified, ransomware likely touched the user data.
//
// Detection logic (with explicit handling of the first-run / mass-nuke
// ambiguity):
//   - failures == 0 and total > 0: clean.
//   - failures > 0 and failures < total: PARTIAL tampering, definitely
//     suspicious. Write canary-failure.flag for the host to act on.
//   - failures == total > 0: ALL canaries missing. Could be the first
//     shutdown of a fresh Clean VM (Boot.exe never ran), OR ransomware
//     deleted everything. We log loudly but do NOT write the flag — the
//     host-side extension scanner will catch the ransomware case via
//     other signals (extensions, ransom notes), and we'd rather take
//     the false-negative here than false-positive on every fresh
//     install's first session.
void verify_canaries() {
	ifstream wl("whitelist.txt");
	if (!wl.is_open()) {
		log_line("INFO  no whitelist.txt; skipping canary verification");
		return;
	}
	int total = 0;
	int failures = 0;
	vector<string> failure_paths;
	string line;
	while (getline(wl, line)) {
		if (line.empty()) continue;
		std::error_code ec;
		if (!fs::is_directory(line, ec)) {
			// Skip non-directory whitelist entries; canaries only live
			// in directories.
			continue;
		}
		total++;
		string canary_path = line + "\\" + CANARY_FILENAME;
		ifstream canary(canary_path);
		if (!canary.is_open()) {
			failures++;
			failure_paths.push_back(canary_path + " (missing)");
			continue;
		}
		string first_line;
		getline(canary, first_line);
		// Strip trailing CR if the file was written with \n and read on a
		// CRLF platform — the magic check should be robust to that.
		if (!first_line.empty() && first_line.back() == '\r') {
			first_line.pop_back();
		}
		if (first_line != CANARY_MAGIC) {
			failures++;
			string sample = first_line.substr(0, 40);
			failure_paths.push_back(canary_path + " (tampered: " + sample + "...)");
			continue;
		}
		// Canary intact.
	}

	if (total == 0) {
		log_line("INFO  no whitelist directories to canary-check");
		return;
	}
	if (failures == 0) {
		log_line("Canary check: " + to_string(total) + "/" + to_string(total) + " intact");
		return;
	}
	if (failures == total) {
		// Ambiguous: first-run OR mass nuke. Log but don't flag.
		log_line("INFO  all " + to_string(total) + " canaries absent — likely first session "
		         "after fresh install (or, less likely, full ransomware sweep). NOT flagging.");
		return;
	}
	// Partial failure — definite tampering signal.
	log_line("CANARY_TAMPERING  " + to_string(failures) + " of " + to_string(total)
	         + " canaries missing or modified:");
	for (const auto& p : failure_paths) {
		log_line("    " + p);
	}
	ofstream flag(SHARED + "\\canary-failure.flag");
	if (flag.is_open()) {
		flag << failures << "/" << total << " canaries failed at " << current_timestamp() << "\n";
		for (const auto& p : failure_paths) {
			flag << p << "\n";
		}
	}
}

void parse_whitelist() {
	string line;
	const string& dir_prefix = SHARED;
	char sep = '\\';
	ifstream in_file("whitelist.txt");
	if (!in_file.is_open()) {
		log_line("ERROR: could not open whitelist.txt");
		exit(1);
	}
	int count = 0;
	ofstream dir_desc(SHARED + "\\dir_desc.txt");
	int failures = 0;
	while (getline(in_file, line)) {
		if (line.empty()) {
			continue;
		}
		// MAX_PATH is 260; SHFileOperation truncates beyond that. Surface
		// it so an admin investigating "missing files" can see the cause.
		if (line.length() >= MAX_PATH) {
			log_line("WARN  path exceeds MAX_PATH and may be truncated: " + line);
		}
		string full_dir = dir_prefix + sep + to_string(count);

		int errCode = 0;
		bool aborted = false;
		bool ok = SHCopy(to_wstring(line).c_str(),
		                 to_wstring(full_dir).c_str(),
		                 errCode, aborted);
		if (!ok) {
			ostringstream o;
			o << "FAIL  copy " << line << " -> " << full_dir
			  << "  errCode=0x" << hex << errCode
			  << (aborted ? " (operation aborted partway)" : "");
			log_line(o.str());
			failures++;
			// IMPORTANT: do NOT increment count on failure. dir_desc lines
			// must correspond positionally to the numbered subfolders that
			// Boot.exe will iterate. If we incremented on failure we'd
			// leave gaps that Boot.exe couldn't detect.
			continue;
		}
		log_line("OK    copy " + line + " -> " + full_dir);
		dir_desc << line << endl;
		count++;
	}
	dir_desc.close();
	if (failures > 0) {
		log_line("WARN  " + to_string(failures) + " whitelist entries failed to copy; "
		         + "boot-side restore will skip them");
	}
}

// generate_whitelist() — build the VM-local whitelist.txt that parse_whitelist()
// reads to decide which directories to copy to the shared folder.
//
// Priority order:
//   1. Staged host-side whitelist at \VBoxSvr\dest\whitelist.txt (written by
//      the host-ui Flask app and copied here by host.sh at cycle start).
//      If present and non-empty, use it verbatim — the admin has explicitly
//      configured what to preserve, so we honour that over the defaults.
//   2. Fallback: the original hardcoded per-user enumeration below. This
//      keeps pre-host-ui deployments working unchanged and gives a safe
//      default for any host that does not yet have ~/osr-config/whitelist.txt.
//
// In both cases the result is written to the VM-local whitelist.txt so the
// rest of the shutdown pipeline (verify_canaries, parse_whitelist) is
// unchanged.
void generate_whitelist() {
	// --- attempt 1: staged host-side whitelist ---
	string staged_path = SHARED + "\\whitelist.txt";
	ifstream staged(staged_path);
	if (staged.is_open()) {
		// Read all non-empty, non-comment lines from the staged file.
		vector<string> entries;
		string ln;
		while (getline(staged, ln)) {
			// Strip trailing CR (file may use LF line endings written on Linux).
			if (!ln.empty() && ln.back() == '\r') ln.pop_back();
			// Skip blank lines and comment lines (# prefix).
			if (ln.empty() || ln[0] == '#') continue;
			entries.push_back(ln);
		}
		if (!entries.empty()) {
			log_line("INFO  using host-staged whitelist (" + to_string(entries.size()) + " entries)");
			ofstream whitelist("whitelist.txt");
			for (const auto& e : entries) {
				whitelist << e << "\n";
			}
			whitelist.close();
			return;
		}
		// File existed but was empty (or all comments) — fall through to defaults.
		log_line("WARN  staged whitelist at " + staged_path + " is empty; using hardcoded defaults");
	} else {
		log_line("INFO  no staged whitelist at " + staged_path + "; using hardcoded defaults");
	}

	// --- attempt 2: hardcoded defaults ---
	ofstream whitelist("whitelist.txt");
	ifstream users("users.txt");
	string line;
	whitelist << "C:\\Users\\Public\\Documents\\Intuit\\QuickBooks\n";
	while (getline(users, line)) {
		for (int i = 0; i < 9; i++) {
			switch (i) {
			case 0:
				whitelist << line << "\\Desktop\n";
				break;
			case 1:
				whitelist << line << "\\Documents\n";
				break;
			case 2:
				whitelist << line << "\\Pictures\n";
				break;
			case 3:
				whitelist << line << "\\Music\n";
				break;
			case 4:
				whitelist << line << "\\Videos\n";
				break;
			case 5:
				whitelist << line << "\\AppData\\Local\\Google\\Chrome\\User Data\\Default\\Bookmarks\n";
				break;
			case 6:
				whitelist << line << "\\AppData\\Roaming\\Microsoft\\Signatures\n";
				break;
			case 7:
				whitelist << line << "\\AppData\\Roaming\\Microsoft\\UProof\n";
				break;
			}
		}
	}
	whitelist.close();
}

void parse_users() {
	string user_dir = "C:\\Users";
	ofstream users("users.txt");
	for (auto& p : fs::directory_iterator(user_dir)) {
		if (p.is_directory()) {
			string user(p.path().string());
			if ( (strcmp(user.c_str(), "Default") != 0) && (strcmp(user.c_str(), "Public") != 0) ) {
				users << user << "\n";
			}
		}
	}
}

bool SHCopy(LPCTSTR from, LPCTSTR to, int& errCode, bool& anyAborted) {
	SHFILEOPSTRUCT fileOp = { 0 };
	fileOp.wFunc = FO_COPY;

	TCHAR newFrom[MAX_PATH];
	_tcscpy_s(newFrom, from);
	newFrom[_tcsclen(from) + 1] = NULL;
	fileOp.pFrom = newFrom;

	TCHAR newTo[MAX_PATH];
	_tcscpy_s(newTo, to);
	newTo[_tcsclen(to) + 1] = NULL;
	fileOp.pTo = newTo;

	// FOF_NOERRORUI is intentional — kiosk machines have no human to
	// dismiss a dialog box. Errors are surfaced via the return code and
	// fAnyOperationsAborted instead of a popup.
	fileOp.fFlags = FOF_SILENT | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_NOCONFIRMMKDIR;

	int result = SHFileOperation(&fileOp);
	errCode = result;
	anyAborted = (fileOp.fAnyOperationsAborted != FALSE);

	return result == 0 && !anyAborted;
}

wstring to_wstring(string str) {
	return strconverter.from_bytes(str);
}
