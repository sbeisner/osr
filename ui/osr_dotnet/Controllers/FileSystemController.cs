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
        private const string OSR_DIR = "C:\\Program Files\\osr_refresh";
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

        public async void createZipArchive()
        {
            string zipName = "clean" + window.getActiveUser().Id;
            string startPath = "C:\\";
            string zipPath = OSR_DIR + "\\" + zipName + ".zip";
            await zipHelper(startPath, zipPath, CompressionLevel.Fastest, true, Encoding.UTF8);
        }

        public async Task zipHelper(
            string sourceDir,
            string destArchiveName,
            CompressionLevel level,
            bool includeBaseDirectory,
            Encoding entryNameEncoding)
        {
            if (string.IsNullOrEmpty(sourceDir))
            {
                throw new ArgumentNullException("sourceDirectoryName");
            }
            if (string.IsNullOrEmpty(destArchiveName))
            {
                throw new ArgumentNullException("desinationArchiveFileName");
            }
            List<string> filesList = await GetFiles(sourceDir);
            Console.WriteLine("\nFinished fetching files. Beginning image\n");
            string zipName = OSR_DIR + "\\"  + "clean" + window.getActiveUser().Id + ".zip";
            if (File.Exists(zipName))
            {
                using (ZipArchive newFile = ZipFile.Open(zipName, ZipArchiveMode.Update))
                {
                    foreach (string file in filesList)
                    {
                        Console.WriteLine("Trying to write " + file + " to  image...\n");
                        try
                        {
                            
                            newFile.CreateEntryFromFile(file, System.IO.Path.GetFileName(file));
                        }
                        catch(Exception e)
                        {
                            Console.WriteLine(e.Message);
                            Console.WriteLine("Failed to write {0} to image", file);
                        }
                    }
                }
            }
            else
            {
                using (ZipArchive newFile = ZipFile.Open(zipName, ZipArchiveMode.Create))
                {
                    foreach (string file in filesList)
                    {
                        Console.WriteLine("Trying to write " + file + " to  image...");
                        try
                        {
                            newFile.CreateEntryFromFile(file, System.IO.Path.GetFileName(file));
                        }
                        catch (Exception e)
                        {
                            Console.WriteLine(e.Message);
                            Console.WriteLine("Failed to write {0} to image", file);
                        }

                    }
                }
            }
        }

        private string[] GetEntryNames(string[] names, string sourceFolder, bool includeBaseName)
        {
            if (names == null || names.Length == 0)
                return new string[0];

            if (includeBaseName)
                sourceFolder = Path.GetDirectoryName(sourceFolder);

            int length = string.IsNullOrEmpty(sourceFolder) ? 0 : sourceFolder.Length;
            if (length > 0 && sourceFolder != null && sourceFolder[length - 1] != Path.DirectorySeparatorChar && sourceFolder[length - 1] != Path.AltDirectorySeparatorChar)
                length++;

            var result = new string[names.Length];
            for (int i = 0; i < names.Length; i++)
            {
                result[i] = names[i].Substring(length);
            }

            return result;
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
