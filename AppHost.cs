using System;
using System.IO;
using System.Threading;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Windows.Forms;
public static class AppHost {
 [STAThread] public static void Main() {
  try {
   using(var runspace=RunspaceFactory.CreateRunspace()) {
    runspace.ApartmentState=ApartmentState.STA;
    runspace.ThreadOptions=PSThreadOptions.UseCurrentThread;
    runspace.Open();
    using(var ps=PowerShell.Create()) {
     ps.Runspace=runspace;
     // Run the local WPF application in-process; no console window is created.
     var root=AppDomain.CurrentDomain.BaseDirectory;
     runspace.SessionStateProxy.SetVariable("WidgetRoot",root);
     runspace.SessionStateProxy.SetVariable("Check",false);
     var learning=File.ReadAllText(Path.Combine(root,"Learning.ps1"));
     var widget=File.ReadAllText(Path.Combine(root,"Widget-v2.ps1"));
     widget=widget.Replace("param([switch]$Check)","").Replace(". (Join-Path $PSScriptRoot 'Learning.ps1')","");
     widget=widget.Replace("$PSScriptRoot","$WidgetRoot");
     ps.AddScript(learning+Environment.NewLine+widget);
     ps.Invoke();
     if(ps.HadErrors) throw new Exception(String.Join(Environment.NewLine,ps.Streams.Error));
    }
   }
  } catch(Exception e) {
   File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"last-error.log"),e.ToString());
   MessageBox.Show(e.Message,"四级背词小窗");
  }
 }
}
