using System;
using System.Windows;
using System.Windows.Controls;

namespace osr_dotnet.Views
{
    /// <summary>
    /// Interaction logic for Configure.xaml — the post-setup landing page
    /// for an already-initialized user. Lets them edit their whitelist or
    /// trigger an immediate snapshot of the current contents.
    /// </summary>
    public partial class Configure : Page
    {
        private MainWindow window;

        public Configure()
        {
            InitializeComponent();
            window = (MainWindow)Application.Current.MainWindow;
        }

        private void Update_Whitelist_Click(object sender, RoutedEventArgs e)
        {
            this.NavigationService.Navigate(new FirstTimeSetup());
        }

        private async void Run_Update_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                await window.initZip();
                MessageBox.Show("Snapshot created.", "Update complete");
            }
            catch (Exception ex)
            {
                MessageBox.Show("Snapshot failed: " + ex.Message, "Error");
            }
        }
    }
}
