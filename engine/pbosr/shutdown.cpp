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
bool SHCopy(LPCTSTR from, LPCTSTR to, int& errCode, bool& anyAborted);
wstring to_wstring(string str);
string current_timestamp();
void log_line(const string& msg);

int main() {
	log_line("=== Shutdown.exe begin ===");
	parse_users();
	generate_whitelist();
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

void generate_whitelist() {
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
