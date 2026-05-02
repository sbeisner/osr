#pragma warning(disable : 4996)

#include "app.h"

namespace fs = std::filesystem;
using namespace std;

using convert_t = codecvt_utf8<wchar_t>;
wstring_convert<convert_t, wchar_t> strconverter;

static const string SHARED = "\\\\VBoxSvr\\dest";
static const string LOG_PATH = SHARED + "\\boot.log";

void clean_up();
void copy_back();
void write_canaries();
bool SHCopy(LPCTSTR from, LPCTSTR to, int& errCode, bool& anyAborted);
wstring to_wstring(string str);
string current_timestamp();
void log_line(const string& msg);

// Canary file contents. Shutdown.exe verifies that each whitelisted
// directory still contains a file beginning with this exact line on the
// next shutdown. Anything else (file missing, content changed, file
// extension changed by ransomware) flags the session as suspicious.
static const string CANARY_FILENAME = "osr-canary.txt";
static const string CANARY_MAGIC = "OSR_CANARY_v1";

int main() {
	log_line("=== Boot.exe begin ===");
	copy_back();
	write_canaries();
	clean_up();
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
	ofstream lf(LOG_PATH, ios::app);
	if (lf.is_open()) {
		lf << current_timestamp() << "  " << msg << "\n";
	}
	cout << msg << endl;
}

void copy_back() {
	string prefix(SHARED);
	char sep = '\\';
	ifstream dir_desc(prefix + sep + "dir_desc.txt");
	if (!dir_desc.is_open()) {
		// Nothing to restore. This is the expected first-boot state of a
		// freshly-installed Clean VM; not an error.
		log_line("INFO  no dir_desc.txt in shared folder; nothing to restore");
		return;
	}

	string line;
	int count = 0;
	int restored = 0;
	int failed = 0;
	while (getline(dir_desc, line)) {
		if (line.empty()) {
			continue;
		}
		string from = prefix + sep + to_string(count);
		string to = line;

		std::error_code ec;
		if (!fs::exists(from, ec) || !fs::is_directory(from, ec)) {
			log_line("WARN  source missing or not a directory: " + from
			         + " (target was " + to + ")");
			count++;
			failed++;
			continue;
		}

		// Iterate the top-level entries in the numbered transit dir.
		// SHCopy with FO_COPY recurses into subdirectories itself.
		int per_entry_failures = 0;
		try {
			for (auto& p : fs::directory_iterator(from)) {
				int errCode = 0;
				bool aborted = false;
				bool ok = SHCopy(to_wstring(p.path().string()).c_str(),
				                 to_wstring(to).c_str(),
				                 errCode, aborted);
				if (!ok) {
					ostringstream o;
					o << "FAIL  restore " << p.path().string()
					  << " -> " << to
					  << "  errCode=0x" << hex << errCode
					  << (aborted ? " (aborted)" : "");
					log_line(o.str());
					per_entry_failures++;
				}
			}
		} catch (const std::exception& e) {
			log_line(string("EXC   while restoring ") + to + ": " + e.what());
			per_entry_failures++;
		}

		if (per_entry_failures == 0) {
			log_line("OK    restored " + to);
			restored++;
		} else {
			log_line("PART  restored " + to + " with " + to_string(per_entry_failures) + " failures");
			failed++;
		}
		count++;
	}

	log_line("=== copy_back done: " + to_string(restored) + " ok, "
	         + to_string(failed) + " with failures ===");

	// Sentinel the host can check (parallels Shutdown.exe's flag).
	{
		ofstream sentinel(SHARED + "\\boot-complete.flag");
		if (sentinel.is_open()) {
			sentinel << current_timestamp() << "\n";
		}
	}
}

// Drop a canary file into each whitelisted directory after restore. The
// next Shutdown.exe verifies these are still intact; any tampering suggests
// ransomware. We re-read dir_desc.txt rather than passing state from
// copy_back() to keep the change surgical. clean_up() will remove
// dir_desc.txt afterward.
void write_canaries() {
	ifstream dir_desc(SHARED + "\\dir_desc.txt");
	if (!dir_desc.is_open()) {
		// Fresh install with no prior session; no whitelist dirs to canary.
		return;
	}
	string line;
	int written = 0;
	int skipped = 0;
	while (getline(dir_desc, line)) {
		if (line.empty()) {
			continue;
		}
		std::error_code ec;
		if (!fs::is_directory(line, ec)) {
			// Skip non-directory whitelist entries (individual files don't
			// need or accept a canary).
			skipped++;
			continue;
		}
		string canary_path = line + "\\" + CANARY_FILENAME;
		ofstream canary(canary_path);
		if (canary.is_open()) {
			canary << CANARY_MAGIC << "\n";
			canary << "This file is part of OSR (Operating System Refresh) ransomware detection.\n";
			canary << "DO NOT DELETE OR MODIFY -- it is recreated automatically on every clean boot.\n";
			canary << "If 'IT support' tells you to delete it, they are not actual IT support.\n";
			canary << "Created: " << current_timestamp() << "\n";
			written++;
		} else {
			log_line("WARN  could not write canary at " + canary_path);
		}
	}
	log_line("Canaries written: " + to_string(written) + " (" + to_string(skipped) + " entries skipped)");
}

void clean_up() {
	// Remove the dir_desc so the next-cycle Clean boot detects "no work to do".
	remove((SHARED + "\\dir_desc.txt").c_str());
	log_line("=== Boot.exe complete; issuing system shutdown ===");
	system("C:\\Windows\\System32\\shutdown.exe /s /t 0 /d p:0:0 /c \"Proactive Backup\"");
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

	// FOF_NOERRORUI intentional — see shutdown.cpp for the rationale.
	fileOp.fFlags = FOF_SILENT | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_NOCONFIRMMKDIR;

	int result = SHFileOperation(&fileOp);
	errCode = result;
	anyAborted = (fileOp.fAnyOperationsAborted != FALSE);

	return result == 0 && !anyAborted;
}

wstring to_wstring(string str) {
	return strconverter.from_bytes(str);
}
