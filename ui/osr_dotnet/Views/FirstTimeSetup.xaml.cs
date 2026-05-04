using Microsoft.Win32;
using Microsoft.WindowsAPICodePack.Dialogs;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Forms;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using System.Windows.Shapes;

namespace osr_dotnet.Views
{
    /// <summary>
    /// Interaction logic for FirstTimeSetup.xaml
    /// </summary>
    public partial class FirstTimeSetup : Page
    {
        private MainWindow window;
        private List<string> savedDirs;
        private string whitelist;
        public FirstTimeSetup()
        {
            savedDirs = new List<string>();
            InitializeComponent();
            window = (MainWindow)System.Windows.Application.Current.MainWindow;
        }

        private void ListBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {

        }

        private void Button_Click(object sender, RoutedEventArgs e)
        {
            CommonOpenFileDialog dialog = new CommonOpenFileDialog();
            dialog.InitialDirectory = window.getActiveUser().TrackedDir;
            dialog.IsFolderPicker = true;
            if (dialog.ShowDialog() == CommonFileDialogResult.Ok)
            {
                savedDirs.Add(dialog.FileName);
                listBox.Items.Add(dialog.FileName);
            }
        }

        private async void Save_Whitelist(object sender, RoutedEventArgs e)
        {
            savedDirs.ForEach(delegate (string dir)
            {
                whitelist += dir + "\n";
            });
            await window.setWhitelist(whitelist);
            await window.finishUserInitialization();
            await window.initZip();
            this.NavigationService.Navigate(new Configure());
        }
    }
}
