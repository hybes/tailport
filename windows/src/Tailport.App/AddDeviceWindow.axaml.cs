using Avalonia.Controls;
using Avalonia.Interactivity;

namespace Tailport.App;

public partial class AddDeviceWindow : Window
{
    public AddDeviceWindow()
    {
        InitializeComponent();
        AddButton.IsEnabled = false;
        AddressBox.TextChanged += (_, _) => AddButton.IsEnabled = !string.IsNullOrWhiteSpace(AddressBox.Text);
        Opened += (_, _) => AddressBox.Focus();
    }

    MainViewModel? ViewModel => DataContext as MainViewModel;

    void ShowError(string? message)
    {
        ErrorText.Text = message;
        ErrorPanel.IsVisible = message is not null;
    }

    void Scan_Click(object? sender, RoutedEventArgs e) => _ = ViewModel?.Model.ScanNetworkAsync();

    void Chip_Click(object? sender, RoutedEventArgs e)
    {
        if ((sender as Control)?.DataContext is PortChip chip) ShowError(chip.Connect());
    }

    void EnterPort_Click(object? sender, RoutedEventArgs e)
    {
        if ((sender as Control)?.DataContext is not ScanHostRow row) return;
        AddressBox.Text = $"{row.Ip}:";
        NameBox.Text = row.Label;
        ShowError(null);
        AddressBox.Focus();
        AddressBox.CaretIndex = AddressBox.Text.Length;
    }

    void Add_Click(object? sender, RoutedEventArgs e)
    {
        if (ViewModel is not { } vm || string.IsNullOrWhiteSpace(AddressBox.Text)) return;
        try
        {
            var device = vm.Model.AddDevice(NameBox.Text ?? "", AddressBox.Text);
            vm.Model.SetEnabled(true, device);
            AddressBox.Text = "";
            NameBox.Text = "";
            ShowError(null);
        }
        catch (TailportException error) { ShowError(error.Message); }
    }

    void Done_Click(object? sender, RoutedEventArgs e) => Close();
}
