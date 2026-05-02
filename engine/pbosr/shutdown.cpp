#pragma warning(disable : 4996)

#include "app.h"

namespace fs = std::filesystem;
using namespace std;

using convert_t = codecvt_utf8<wchar_t>;
wstring_convert<convert_t, wchar_t> strconverter;

void generate_whitelist();
void parse_users();
void parse_whitelist();
bool SHCopy(LPCTSTR from, LPCTSTR to);
wstring to_wstring(string str);

int main() {
	parse_users();
	generate_whitelist();
	parse_whitelist();

	remove("users.txt");
	remove("whitelist.txt");
	ofstream complete_file("running_clean.txt");
	
	system("C:\\Windows\\System32\\shutdown.exe /s /t 0 /d p:0:0 /c \"Proactive Backup\"");
}

void parse_whitelist() {
	string line;
	string dir_prefix("\\\\VBoxSvr\\dest");
	char sep = '\\';
	ifstream in_file("whitelist.txt");
	if (!in_file.is_open()) {
		cerr << "Could not open whitelist" << endl;
		exit(1);
	}
	string user;
	int count = 0;
	ofstream dir_desc("\\\\VBoxSvr\\dest\\dir_desc.txt");
	while (getline(in_file, line)) {
		fs::path src_path(line);
		string full_dir("");
		string dest_path(to_string(count));
		full_dir += dir_prefix + sep + dest_path;
		
		if (!SHCopy(to_wstring(line).c_str(), to_wstring(full_dir).c_str())) {
			cerr << "Error copying from " << line << " to: " << full_dir << endl << endl;
			continue;
		}
		cout << "Successful copy from " << line << " to " << full_dir << endl << endl;
		dir_desc << line << endl;
		count++;
	}
	dir_desc.close();
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

bool SHCopy(LPCTSTR from, LPCTSTR to) {

	cout << "Recursive file copy from " << from << " to " << to << endl;

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

	fileOp.fFlags = FOF_SILENT | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_NOCONFIRMMKDIR;

	int result = SHFileOperation(&fileOp);

	cout << "SHFileOperation return code: 0x" << result << endl;

	return result == 0;
}

wstring to_wstring(string str) {
	return strconverter.from_bytes(str);
}



