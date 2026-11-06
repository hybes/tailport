using Avalonia.Controls;
using Avalonia.Interactivity;

namespace Tailport.App;

public partial class ExclusionsWindow : Window
{
    readonly AppModel? model;

    public ExclusionsWindow() => InitializeComponent();

    public ExclusionsWindow(AppModel model) : this()
    {
        this.model = model;
        PortsBox.Text = model.IgnoredPorts;
        ProcessesBox.Text = model.IgnoredProcesses;
    }

    void Defaults_Click(object? sender, RoutedEventArgs e)
    {
        PortsBox.Text = IgnoreRules.DefaultPorts;
        ProcessesBox.Text = IgnoreRules.DefaultProcesses;
        ErrorPanel.IsVisible = false;
    }

    void Cancel_Click(object? sender, RoutedEventArgs e) => Close();

    void Save_Click(object? sender, RoutedEventArgs e)
    {
        try
        {
            model?.ApplyExclusions(PortsBox.Text ?? "", ProcessesBox.Text ?? "");
            Close();
        }
        catch (TailportException error)
        {
            ErrorText.Text = error.Message;
            ErrorPanel.IsVisible = true;
        }
    }
}
