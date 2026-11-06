using System.Windows.Input;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace Tailport.App;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        RefreshCommand = new Command(() => _ = ViewModel?.Model.RefreshAsync());
    }

    public ICommand RefreshCommand { get; }
    MainViewModel? ViewModel => DataContext as MainViewModel;

    void AddDevice_Click(object? sender, RoutedEventArgs e)
    {
        if (ViewModel is { } vm) _ = new AddDeviceWindow { DataContext = vm }.ShowDialog(this);
    }

    void Exclusions_Click(object? sender, RoutedEventArgs e)
    {
        if (ViewModel is { } vm) _ = new ExclusionsWindow(vm.Model).ShowDialog(this);
    }

    void Refresh_Click(object? sender, RoutedEventArgs e) => _ = ViewModel?.Model.RefreshAsync();

    static T? Row<T>(object? sender) where T : class => (sender as Control)?.DataContext as T;

    void OpenDevice_Click(object? sender, RoutedEventArgs e) => Row<DeviceRow>(sender)?.Open();

    void RemoveDevice_Click(object? sender, RoutedEventArgs e)
    {
        if (Row<DeviceRow>(sender) is { } row) ViewModel?.Model.RemoveDevice(row.Device);
    }

    void OpenPort_Click(object? sender, RoutedEventArgs e) => Row<PortRow>(sender)?.Open();

    void ExcludePort_Click(object? sender, RoutedEventArgs e) => Row<PortRow>(sender)?.Exclude();
}

sealed class Command(Action action) : ICommand
{
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => action();
}
