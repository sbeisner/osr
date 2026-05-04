using System;
using System.Collections.Generic;
using System.Linq;
using System.Management;
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
    /// Interaction logic for SelectUser.xaml
    /// </summary>
    public partial class SelectUser : Page
    {
        private MainWindow window;
        public SelectUser()
        {
            window = (MainWindow)Application.Current.MainWindow;
            SelectQuery query = new SelectQuery("Win32_UserAccount");
            ManagementObjectSearcher searcher = new ManagementObjectSearcher(query);
            InitializeComponent();
            foreach (ManagementObject envVar in searcher.Get())
            {
                comboBox.Items.Add(envVar["Name"]);
            }
        }

        private async void Button_Click(object sender, RoutedEventArgs e)
        {
            string dir = "C:\\Users\\" + comboBox.SelectedItem.ToString();
            Console.WriteLine("Updating user entry in databse with {0}\n", dir);
            await window.setUserDir(dir);
            this.NavigationService.Navigate(new FirstTimeSetup());
        }

        private void comboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {

        }
    }
}
