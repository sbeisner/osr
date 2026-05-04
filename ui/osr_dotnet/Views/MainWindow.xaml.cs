using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace osr_dotnet.Views
{
    using osr_dotnet.Controllers;
    using osr_dotnet.Models;
    /// <summary>
    /// Interaction logic for MainWindow.xaml
    /// </summary>
    public partial class MainWindow : Window
    {
        private const string LOGIN_PATH = "Login.xaml";
        private const string ACCOUNT_CREATE_PATH = "AccountCreate.xaml";
        private int window_state = 0;
        public LocalUserStore userStore;
        public FileSystemController fileSystemController;
        private User activeUser;

        public string Current_Page
        {
            get
            {
                switch (window_state)
                {
                    case 0:
                        return LOGIN_PATH;
                    case 1:
                        return ACCOUNT_CREATE_PATH;
                    default:
                        return LOGIN_PATH;
                }
            }
        }

        public MainWindow()
        {
            asyncIntialize();     
        }

        public async void asyncIntialize()
        {
            userStore = await startUserStore();
            loadFileSystemController();
            DataContext = this;
            InitializeComponent();
        }

        public void loadFileSystemController()
        {
            fileSystemController = new FileSystemController();
        }

        private async Task<LocalUserStore> startUserStore()
        {
            try
            {
                var store = new LocalUserStore();
                Console.WriteLine("Booting...\n");
                await store.startAsync();
                return store;
            }
            catch (Exception e)
            {
                Console.WriteLine("Error loading user store: {0}", e);
                return null;
            }
            finally
            {
                Console.WriteLine("End of startup");
            }
        }

        public LocalUserStore getUserStore()
        {
            return userStore;
        }

        public void setActiveUser(User user)
        {
            activeUser = user;
        }

        public User getActiveUser()
        {
            return activeUser;
        }

        public async Task setUserDir(string dir)
        {
            activeUser.TrackedDir = dir;
            await userStore.UpdateUser(activeUser);
        }

        public async Task setWhitelist(string whitelist)
        {
            activeUser.Whitelist = whitelist;
            await userStore.UpdateUser(activeUser);
        }

        public async Task finishUserInitialization()
        {
            activeUser.IsInitialized = "true";
            await userStore.UpdateUser(activeUser);
        }

        public async Task initZip()
        {
            if (fileSystemController != null)
            {
                await fileSystemController.createZipArchive();
            }
        }
    }
}
