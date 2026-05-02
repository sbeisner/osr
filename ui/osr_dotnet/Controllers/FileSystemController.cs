using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.IO.Compression;
using osr_dotnet.Views;

namespace osr_dotnet.Controllers
{
    public class FileSystemController
    {
        // Stored under %LOCALAPPDATA%\osr (typically C:\Users\<u>\AppData\Local\osr)
        // so the app does not require admin to write archives.
        private static readonly string OSR_DIR = System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "osr");
        private MainWindow window;
        private bool isInitialzied = false;
        private string userDir;

        public FileSystemController()
        {
            window = (MainWindow)System.Windows.Application.Current.MainWindow;
            try
            {
                if (Directory.Exists(OSR_DIR))
                {
                    Console.WriteLine("Returning User. {0} already exists\n", OSR_DIR);
                    isInitialzied = true;
                }
                else
                {
                    DirectoryInfo di = Directory.CreateDirectory(OSR_DIR);
                    Console.WriteLine("The directory was created successfully at {0}", Directory.GetCreationTime(OSR_DIR));
                }
            }
            catch (Exception e)
            {
                Console.WriteLine("The Process failed: {0}", e.ToString());
            }
            
        }

        public async Task createZipArchive()
        {
            var user = window?.getActiveUser();
            if (user == null)
            {
                Console.WriteLine("createZipArchive: no active user");
                return;
            }
            if (string.IsNullOrWhiteSpace(user.Whitelist))
            {
                Console.WriteLine("createZipArchive: whitelist is empty; nothing to archive");
                return;
            }

            string zipPath = Path.Combine(OSR_DIR, "snapshot-" + user.Id + ".zip");
            if (File.Exists(zipPath))
            {
                File.Delete(zipPath);
            }

            var roots = user.Whitelist
                .Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(p => p.Trim())
                .Where(p => !string.IsNullOrEmpty(p))
                .ToList();

            using (ZipArchive zip = ZipFile.Open(zipPath, ZipArchiveMode.Create))
            {
                foreach (string root in roots)
                {
                    string rootName = Path.GetFileName(root.TrimEnd('\\', '/'));
                    if (string.IsNullOrEmpty(rootName)) rootName = "root";

                    if (File.Exists(root))
                    {
                        AddEntry(zip, root, rootName);
                        continue;
                    }
                    if (!Directory.Exists(root))
                    {
                        Console.WriteLine("Whitelist entry not found, skipping: {0}", root);
                        continue;
                    }

                    List<string> files = await GetFiles(root);
                    foreach (string file in files)
                    {
                        string remainder = file.Substring(root.Length).TrimStart('\\', '/');
                        string entryName = string.IsNullOrEmpty(remainder)
                            ? rootName
                            : rootName + "\\" + remainder;
                        AddEntry(zip, file, entryName);
                    }
                }
            }
            Console.WriteLine("Wrote archive to {0}", zipPath);
        }

        private static void AddEntry(ZipArchive zip, string sourceFile, string entryName)
        {
            try
            {
                zip.CreateEntryFromFile(sourceFile, entryName, CompressionLevel.Fastest);
            }
            catch (Exception e)
            {
                Console.WriteLine("Skipped {0}: {1}", sourceFile, e.Message);
            }
        }

        private async Task<List<string>> GetFiles(string sourceDir)
        {
            var files = new List<string>();
            Console.WriteLine("\tEntering directory: {0}\n", sourceDir);
            try
            {
                var dirFiles = Directory.GetFiles(sourceDir);
                foreach (string file in dirFiles)
                {
                    files.Add(file);
                }
            }
            catch (Exception e)
            {
                Console.WriteLine(e.Message);
            }
            try
            {
                var subDirs = Directory.GetDirectories(sourceDir);
                foreach (string subDir in subDirs)
                {
                    files.AddRange(await GetFiles(subDir));
                }
            }
            catch (Exception e)
            {
                Console.WriteLine(e.Message);
            }
            return files;
        }
    }
}
