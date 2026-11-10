function Delete-UserChoiceKey {
  param (
    [Parameter( Position = 0, Mandatory = $True )]
    [String]
    $Key
  )
  # RegDeleteKey on HKEY_USERS (0x80000003), as the C# helper this replaces did. The P/Invoke is defined in
  # memory (Reflection.Emit) instead of Add-Type: Add-Type starts csc.exe, which sat blocked in IPC calls for
  # about 30 s during the playbook run (measured on the Hyper-V test VM) and nothing else was waiting on it.
  # The helper also opened the key first (RegOpenKeyEx) but never used the handle; that call is dropped.
  if (-not ('Registry.Utils' -as [type])) {
    $ab = [AppDomain]::CurrentDomain.DefineDynamicAssembly((New-Object Reflection.AssemblyName 'RegistryUtilsDyn'), [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $tb = $ab.DefineDynamicModule('RegistryUtilsDyn').DefineType('Registry.Utils', 'Public,Class')
    $null = $tb.DefinePInvokeMethod('RegDeleteKey', 'advapi32.dll', 'Public,Static,PinvokeImpl', 'Standard', [uint32], @([UIntPtr], [string]), 'Winapi', 'Unicode')
    $null = $tb.CreateType()
  }
  [void][Registry.Utils]::RegDeleteKey([UIntPtr]::new([uint64]2147483651), $Key)
}

$Hive = $args[1]

Write-Host "Setting file associations for HKEY_USERS\$Hive..."

New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null

If (-NOT (Test-Path "HKU:\$Hive\SOFTWARE\Clients")) {
New-Item -Path "HKU:\$Hive\SOFTWARE\Clients" -Force | Out-Null
}
If (-NOT (Test-Path "HKU:\$Hive\SOFTWARE\Clients\StartMenuInternet")) {
New-Item -Path "HKU:\$Hive\SOFTWARE\Clients\StartMenuInternet" -Force | Out-Null
}

Get-Item -Path "HKLM:\SOFTWARE\Clients\StartMenuInternet\*" |
ForEach-Object {
Copy-Item -Path "$($_.PSPath)" -Destination "HKU:\$Hive\SOFTWARE\Clients\StartMenuInternet" -Force -Recurse | Out-Null
}

for ($i = 2; $i -lt $args.Length; $i++) {
  $splitArg = $args[$i] -split ":"
  if ($splitArg[0] -eq "Proto") {
    If (-NOT (Test-Path "HKU:\$Hive\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\$($splitArg[1])")) {
    New-Item -Path "HKU:\$Hive\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\$($splitArg[1])" -Force | Out-Null
    }
    If (Test-Path "HKU:\$Hive\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\$($splitArg[1])\UserChoice") {
    Delete-UserChoiceKey "$Hive\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\$($splitArg[1])\UserChoice"
    }
    If (-NOT (Test-Path "HKU:\$Hive\SOFTWARE\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts")) {
    New-Item -Path "HKU:\$Hive\SOFTWARE\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts" -Force | Out-Null
    }
    New-ItemProperty -Path "HKU:\$Hive\SOFTWARE\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts" -Name "$($splitArg[2])_$($splitArg[1])" -PropertyType DWORD -Value 0 -Force | Out-Null
  } else {
    If (-NOT (Test-Path "HKU:\$Hive\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$($splitArg[0])")) {
    New-Item -Path "HKU:\$Hive\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$($splitArg[0])" -Force | Out-Null
    } 
    If (Test-Path "HKU:\$Hive\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$($splitArg[0])\UserChoice") {
    Delete-UserChoiceKey "$Hive\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$($splitArg[0])\UserChoice"
    }
    If (-NOT (Test-Path "HKU:\$Hive\SOFTWARE\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts")) {
    New-Item -Path "HKU:\$Hive\SOFTWARE\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts" -Force | Out-Null
    }
    New-ItemProperty -Path "HKU:\$Hive\SOFTWARE\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts" -Name "$($splitArg[1])_$($splitArg[0])" -PropertyType DWORD -Value 0 -Force | Out-Null

    [Microsoft.Win32.Registry]::SetValue("HKEY_CLASSES_ROOT\$($splitArg[0])", "", "$($splitArg[1])")
    [Microsoft.Win32.Registry]::SetValue("HKEY_USERS\$Hive\SOFTWARE\Classes\$($splitArg[0])", "", "$($splitArg[1])")
  }
}