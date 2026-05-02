#pragma warning(disable : 4996)

#include "app.h"

namespace fs = std::filesystem;
using namespace std;

using convert_t = codecvt_utf8<wchar_t>;
wstring_convert<convert_t, wchar_t> strconverter;

void clean_up();
void copy_back();
bool SHCopy(LPCTSTR from, LPCTSTR to);
wstring to_wstring(string str);

int main() {
	copy_back();
	clean_up();
	
}

void copy_back() {
	string prefix("\\\\VBoxSvr\\dest");
	char sep = '\\';
	ifstream dir_desc(prefix + sep + "dir_desc.txt");
	string line;
	if (dir_desc.is_open()) {
		int count = 0;
		while (getline(dir_desc, line)) {
			string from = prefix + sep + to_string(count);
			string to = line;
			for (auto& p : fs::directory_iterator(from)) {
				SHCopy(to_wstring(p.path().string()).c_str(), to_wstring(to).c_str());
			}
			//SHCopy(to_wstring(from).c_str(), to_wstring(to).c_str());
			count++;
		}
	}
	else {
		exit(0);
	}
}
void clean_up() {
	remove("\\\\VBoxSvr\\dest\\dir_desc.txt");
	system("C:\\Windows\\System32\\shutdown.exe /s /t 0 /d p:0:0 /c \"Proactive Backup\"");
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