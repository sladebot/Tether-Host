// Tether Guest Installer is a single Linux executable carrying its guide and
// backend. It uses Debian Desktop's system GTK Python bindings, not a shell UI.
package main

import (
 "archive/zip"
 "bytes"
 _ "embed"
 "fmt"
 "io"
 "os"
 "os/exec"
 "path/filepath"
 "strings"
)

//go:embed payload.zip
var payload []byte

func unpack(data []byte, destination string) error {
 archive, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
 if err != nil { return err }
 for _, item := range archive.File {
  if filepath.Base(item.Name) != item.Name || strings.ContainsAny(item.Name, `/\\`) || item.Name == "." || item.Mode() & os.ModeSymlink != 0 || item.UncompressedSize64 > 8*1024*1024 { return fmt.Errorf("invalid bundled resource") }
  input, err := item.Open(); if err != nil { return err }
  output, err := os.OpenFile(filepath.Join(destination,item.Name), os.O_WRONLY|os.O_CREATE|os.O_EXCL,0700)
  if err != nil { input.Close(); return err }
  _, err = io.Copy(output,io.LimitReader(input,8*1024*1024+1))
  input.Close(); closeErr := output.Close()
  if err != nil { return err }; if closeErr != nil { return closeErr }
 }
 return nil
}

func failure(message string) {
 fmt.Fprintln(os.Stderr,message)
 // Stock Debian's graphical error fallback; no external terminal is needed.
 _ = exec.Command("zenity","--error","--title=Tether Guest Installer","--text="+message).Run()
}

func selfTest() int {
 directory, err := os.MkdirTemp("", "tether-guest-installer-self-test-")
 if err != nil { fmt.Fprintln(os.Stderr, err); return 1 }
 defer os.RemoveAll(directory)
 if err := unpack(payload, directory); err != nil { fmt.Fprintln(os.Stderr, err); return 1 }
 required := []string{"guest_installer.py", "setup.sh", "update-guest-tools.sh", "linux_guest_setup.py", "session-start.sh", "components.json"}
 for _, name := range required {
  info, err := os.Stat(filepath.Join(directory, name))
  if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
   fmt.Fprintln(os.Stderr, "missing bundled resource:", name)
   return 1
  }
 }
 fmt.Println("TETHER_GUEST_INSTALLER_SELF_TEST_OK")
 return 0
}

func run() int {
 if len(os.Args) == 2 && os.Args[1] == "--self-test" { return selfTest() }
 if os.Geteuid() == 0 { failure("Open Tether Guest Installer as your normal Debian desktop account, without sudo."); return 1 }
 if os.Getenv("DISPLAY") == "" && os.Getenv("WAYLAND_DISPLAY") == "" { failure("Open this installer from the Debian desktop."); return 1 }
 check := exec.Command("/usr/bin/python3","-c","import gi; gi.require_version('Gtk', '3.0'); from gi.repository import Gtk")
 if err := check.Run(); err != nil { failure("This installer needs Debian Desktop with Python 3 and GTK 3 bindings. Use the supported Debian Desktop image; the graphical runtime is unavailable."); return 1 }
 directory,err := os.MkdirTemp("","tether-guest-installer-")
 if err != nil { failure("Could not prepare installer files: "+err.Error()); return 1 }
 defer os.RemoveAll(directory)
 if err := unpack(payload,directory); err != nil { failure("The bundled installer could not be opened: "+err.Error()); return 1 }
 command := exec.Command("/usr/bin/python3",filepath.Join(directory,"guest_installer.py"))
 command.Env=os.Environ()
 command.Stdin=os.Stdin; command.Stdout=os.Stdout; command.Stderr=os.Stderr
 if err := command.Run(); err != nil { return 1 }
 return 0
}
func main(){ os.Exit(run()) }
