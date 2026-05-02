using osr_dotnet.Controllers;
using osr_dotnet.Models;
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
using System.Windows.Navigation;
using System.Windows.Shapes;

namespace osr_dotnet.Views
{
    /// <summary>
    /// Interaction logic for MainWindow.xaml
    /// </summary>
    public partial class Login : Page
    {
        private MainWindow window;
        private CosmosController cosmosController;
        public Login()
        {
            InitializeComponent();
            window = (MainWindow)Application.Current.MainWindow;
            cosmosController = window.getCosmosController();

        }

        private void Switch_Create(object sender, RoutedEventArgs e)
        {
            this.NavigationService.Navigate(new AccountCreate());
        }

        private async void Login_Click(object sender, RoutedEventArgs e)
        {
            string email = email_box.Text;
            string password = password_box.Password;
            User user = await cosmosController.QueryUsersAsync(email, password);
            window.setActiveUser(user);
            if (user.IsInitialized.Equals("false"))
            {
                this.NavigationService.Navigate(new SelectUser());
            }
            else
            {

            }
            
        }
    }
}
