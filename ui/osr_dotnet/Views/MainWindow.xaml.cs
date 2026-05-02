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
using Microsoft.Azure.Cosmos;

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
        public CosmosController cosmosController;
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
            cosmosController = await startDatabaseController();
            loadFileSystemController();
            DataContext = this;
            InitializeComponent();
        }

        public void loadFileSystemController()
        {
            fileSystemController = new FileSystemController();
        }

        private async Task<CosmosController> startDatabaseController()
        {
            CosmosController cC;
            try
            {
                cC = new CosmosController();
                Console.WriteLine("Booting...\n");
                await cC.startAsync();
                return cC;
            }
            catch (CosmosException de)
            {
                Exception baseException = de.GetBaseException();
                Console.WriteLine("{0} error occured: {1}", de.StatusCode, de);
                return null;
            }
            catch (Exception e)
            {
                Console.WriteLine("Error: {0}", e);
                return null;
            }
            finally
            {
                Console.WriteLine("End of startup");
            }
        }
        public CosmosController getCosmosController()
        {
            return cosmosController;
        }

        public void setActiveUser(User user)
        {
            activeUser = user;
        }

        public User getActiveUser()
        {
            return activeUser;
        }

        public async void setUserDir(string dir)
        {
            activeUser.TrackedDir = dir;
            await cosmosController.UpdateUser(activeUser);
        }

        public async void setWhitelist(string whitelist)
        {
            activeUser.Whitelist = whitelist;
            await cosmosController.UpdateUser(activeUser);
        }

        public async void finishUserInitialization()
        {
            activeUser.IsInitialized = "true";
            await cosmosController.UpdateUser(activeUser);
        }

        public void initZip()
        {
            fileSystemController.createZipArchive();
        }
    }
}
