using System;
using System.Collections.Generic;
using System.Linq;
using System.Security;
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
    using osr_dotnet.Models;
    using osr_dotnet.Controllers;
    /// <summary>
    /// Interaction logic for AccountCreate.xaml
    /// </summary>
    public partial class AccountCreate : Page
    {
        private string _status_label_content;
        private int status_state = 0;
        private const string NULL_STATUS = "";
        private const string SUCCESS_STATUS = "Success";
        private const string NO_MATCH_STATUS = "Passwords do not match. Try again.";
        private const string MISSING_FIELD_STATUS = "Please enter information for all required fields and try again";
        private MainWindow window;
        private LocalUserStore userStore;

        public AccountCreate()
        {
            InitializeComponent();
            window = (MainWindow)Application.Current.MainWindow;
            userStore = window.getUserStore();

        }

        private async void Save_Account_To_DB(object sender, RoutedEventArgs e)
        {
            //status_label.Content = "";
            string full_name = name_box.Text;
            string email = email_box.Text;
            string pass1 = password_1.Password;
            string pass2 = password_2.Password;
            if (String.Equals(full_name,"") || String.Equals(email,"") || String.Equals(pass1, "") || String.Equals(pass2,""))
            {
                status_label.Content = MISSING_FIELD_STATUS;
            }
            else if (!String.Equals(pass1,pass2))
            {
                status_label.Content = NO_MATCH_STATUS;
            }
            else
            {
                User new_user = new User();
                new_user.Name = full_name;
                new_user.Email = email;
                new_user.Password = BCrypt.Net.BCrypt.HashPassword(pass1);
                new_user.DateLicenseIssued = DateTime.Today.ToString();
                new_user.DateLicenseExpires = DateTime.Today.AddYears(1).ToString();
                new_user.IsInitialized = "false";
                new_user.Id = Guid.NewGuid().ToString();

                await userStore.AddUsersToContainerAsync(new_user);
                status_label.Content = SUCCESS_STATUS;
                
            }


        }
    }
}
