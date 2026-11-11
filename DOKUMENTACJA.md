# XENServer_migration - dokumentacja

# XenServer / Citrix Tools cleanup - dokumentacja

Wersja: 1.0, 2026-11-11. Plik: Remove-XenTools.ps1.

## 1. Cel, zalozenia i status walidacji

Skrypt wykonuje audyt, standardowa deinstalacje wskazanego produktu MSI oraz
etapowe czyszczenie pozostalosci Xen po migracji do Hyper-V. Komentarze i komunikaty
w PS1 sa po polsku bez znakow diakrytycznych, aby ograniczyc problemy kodowania.

Zalozenia:
- Windows Server 2016 lub nowszy, Windows PowerShell 5.1 x64, administrator.
- Zainstalowane moduly PnpDevice i Dism oraz dzialajace CIM/WMI.
- Kopia calej VM, sprawdzona mozliwosc odtworzenia, okno serwisowe i konsola hypervisora.
- Czyszczenie sterownikow tylko na uruchomionej kopii docelowej na Hyper-V.
- Zakres ghost devices: tylko rozpoznane, nieobecne urzadzenia Xen. Pozostale ghost
  devices sa raportowane, ale NIE sa automatycznie usuwane.

To jest implementacja przygotowana na podstawie analizy kodu i dokumentacji,
nie skrypt certyfikowany przez producenta. Nie uruchomiono go na Windows ani na VM
uzytkownika. W srodowisku tworzenia nie ma PowerShell, dlatego NIE wykonano nawet
walidacji parserem PowerShell. Wykonano przeglad statyczny zabezpieczen i spojnosci
plikow. Przed produkcja wymagane sa parser i test na odtwarzalnym klonie.

## 2. Analiza materialow zrodlowych

### 2.1. Artykul o migracji [S1]

Artykul z 2019 r. opisuje XenServer 7.6, Hyper-V 2016 i Windows Server 2016.
Kolejnosc autora: snapshot, deinstalacja agenta, restart, ghost devices, pliki
sterownikow, konwersja, kontrola VHDX. Autor opisuje ponowne pojawianie sie plikow
po restarcie i problemy startu po migracji.

Nie jest to uniwersalna instrukcja dla kazdej wersji Tools. W proponowanym skrypcie
swiadomie NIE odtwarzam agresywnego czyszczenia sterownikow na dzialajacym Xen.
Jesli kopia nie uruchamia sie na Hyper-V, faza Cleanup nie pomoze: potrzebna jest
osobna procedura naprawy obrazu offline. Nie usuwaj w ciemno sterownikow z VM zrodlowej.

Blad powloki w artykule: `set devmgr_show_nonpresent_devices=1` jest skladnia CMD,
a nie ustawieniem zmiennej srodowiskowej w PowerShell. W PowerShell:

```powershell
$env:devmgr_show_nonpresent_devices = '1'
Start-Process devmgmt.msc
```

`Push-Location` zmienia katalog i odklada poprzednia lokalizacje na stos.
`?` to alias `Where-Object`, a `-like 'xen*'` jest szerokim dopasowaniem nazwy,
nie potwierdzeniem producenta ani bezpieczenstwa usuniecia pliku.

### 2.2. removeGhost.ps1 [S2]

Przydatne elementy:
- P/Invoke przez Add-Type i SetupAPI, niezaleznosc od dodatkowego devcon.exe.
- Filtrowanie klas i nazw, tryby listowania oraz potwierdzenia.

Problemy logiczne i skladniowe:
1. `$InstallState = SetupDiGetDeviceRegistryProperty(...)` przypisuje BOOL powodzenia
   wywolania API, a nie wartosc SPDRP_INSTALL_STATE z bufora. Niepowodzenie odczytu
   nie dowodzi, ze urzadzenie jest nieobecne. To glowny blad kwalifikacji ghost devices.
2. `-Force` pomija potwierdzenia, a brak zawazenia moze objac inne urzadzenia niz Xen.
3. `SetupDiRemoveDevice` wywolywane bezposrednio nie jest tym samym co pelna sciezka
   instalatorow i co-installerow przez DIF_REMOVE / SetupDiCallClassInstaller [S5].
4. W widocznym kodzie brak wywolania SetupDiDestroyDeviceInfoList po enumeracji,
   mimo zadeklarowania tej funkcji. Uchwyt powinien byc zwalniany w finally.
5. Obiekt jest dodawany do removeArray przed sprawdzeniem wyniku usuniecia.
   Raport 'removed' moze zawierac nieudane proby.
6. `Format-Table` jest prezentacja, nie zwracaniem surowych obiektow. Koncowe
   `return $filteredDevices | Out-Null` tlumi wynik, mimo przykladow przypisywania
   listy do zmiennej.
7. `if (!$Force -eq $true)` jest niepotrzebnie trudne do czytania; `if (-not $Force)`
   przekazuje ten sam zamiar prosciej.

Widok HTML kodu w narzedziu odczytu zawieral artefakty formatowania. Nie uznaje ich
za potwierdzone bledy skladni w pliku RAW. Powyzsze uwagi dotycza widocznej logiki,
a nie rzekomego wyniku uruchomienia parsera.

### 2.3. xenserver-tools-remover.ps1 [S3]

- `sc.exe` jest poprawnym jawnym wywolaniem programu. Samo `sc` w Windows PowerShell
  moze oznaczac alias Set-Content.
- `gwmi`, `%`, `rm`, `-fo` to odpowiednio Get-WmiObject, ForEach-Object, Remove-Item
  i skrocony parametr Force. W kodzie utrzymywanym operacyjnie lepsze sa pelne nazwy.
- Lista uslug ma powtorzone xenvif oraz ogolne nazwy XEN/installagent. Bez weryfikacji
  tozsamosci nie powinny byc usuwane automatycznie.
- `gwmi win32_pnpentity | % { gwmi -query ... }` wykonuje to samo zapytanie o sterownik
  dla kazdego urzadzenia PnP. To nie jest filtrowanie ghost devices. Powoduje wiele
  zbednych wywolan StopService/Delete.
- Skrypt nie wykonuje standardowej deinstalacji produktu MSI. Usuniecie uslug nie
  oznacza odinstalowania produktu ani usuniecia pakietu z Driver Store.
- `rm c:\windows\system32\xen*` nie wskazuje katalogu System32\drivers i nie ma
  -Recurse. Nie realizuje wprost usuniecia xen*.sys z katalogu sterownikow.
- `rm c:\ProgramData\Citrix*` ma zbyt szeroki zakres: moze dotyczyc danych innych
  produktow Citrix. Brak -Recurse nie jest zabezpieczeniem tozsamosci produktu.
- `Set-ItemProperty ... UpperFilters -Value @()` zeruje cala liste, jesli jest na niej
  XENFILT. Moze usunac takze inne filtry. Nalezy odjac tylko wpis xenfilt i zachowac reszte.
- Na sztywno podane CurrentControlSet/ControlSet001/ControlSet002 dubluja aktywny
  zestaw i nie obejmuja dowolnych innych zestawow.
- Brak kopii, kontroli kodow sc.exe, obslugi restartu, audytu i pelnej kontroli bledow.

## 3. Projekt nowego skryptu

### Audit

Domyslny tryb. Odczytuje produkty z obu galezi Uninstall rejestru, urzadzenia PnP,
pakiety przez Get-WindowsDriver, uslugi, filtry klas i pliki xen*.sys.
Nie korzysta z Win32_Product: Microsoft opisuje skutki uboczne w postaci sprawdzania
i naprawy pakietow MSI [S6]. Zapisuje raporty, ale nie zmienia konfiguracji systemu.

### Uninstall

Wymaga -Execute, -BackupConfirmed oraz jawnego -ProductCode. Sprawdza, czy GUID
jest w raporcie kandydatow Xen i czy produkt jest MSI. Nie wykonuje dowolnego
UninstallString i nie uzywa Invoke-Expression.

Wykonuje msiexec /x /qn /norestart REBOOT=ReallySuppress z logiem. Akceptuje 0, 3010
oraz 1641; po jednym udanym produkcie konczy przebieg kodem 3010. Kod 1641 oznacza,
ze instalator zainicjowal restart: nie jest gwarancja, ze proces zdazy zapisac raport.
Skrypt sam nie wywoluje Restart-Computer, ale nie moze zagwarantowac zachowania
zewnetrznego instalatora.

Na XenServer faza wymaga dodatkowo -AllowSourceUninstall. To zgoda tylko na normalna
deinstalacje producenta, NIE na usuwanie aktywnych sterownikow. Mozliwa utrata sieci
lub zmiana sposobu dostepu do dysku. Uruchamiaj z konsoli na klonie.

### Cleanup

1. Sprawdza Manufacturer=Microsoft Corporation i Model=Virtual Machine oraz brak
   obecnych urzadzen Xen. To konserwatywna kontrola srodowiska, nie dowod kryptograficzny
   platformy. Nietypowe metadane VM moga spowodowac blokade.
2. Wymaga braku zainstalowanych kandydatow Tools oraz braku oczekujacego restartu.
3. Ghost = InstanceId obecne na liscie wszystkich urzadzen, ale nie na liscie
   Get-PnpDevice -PresentOnly. Status Unknown nie jest kryterium usuniecia.
4. Xen jest rozpoznawany po konkretnych prefiksach InstanceId, PCI VEN_5853 lub
   dokladnej nazwie uslugi sterownika. Sama nazwa zawierajaca Citrix nie wystarcza.
5. Usuwa nieobecne urzadzenia przez DIF_REMOVE / SetupDiCallClassInstaller. Zwalnia
   uchwyt w finally i odczytuje flagi DI_NEEDRESTART/DI_NEEDREBOOT [S5].
6. Eksportuje rozpoznany pakiet, nastepnie pnputil /delete-driver oemNN.inf.
   Bez /force, /uninstall i /reboot. Nie usuwa recznie DriverStore ani katalogu INF [S4].
7. Z UpperFilters i LowerFilters w drzewach Control\Class rzeczywistych ControlSetNNN
   usuwa tylko xenfilt. Zachowuje inne wpisy, eksportuje klucz przed zmiana.
8. Po zmianie filtrow wymaga restartu. Dopiero pozniej usuwa rozpoznane uslugi.
   Nie zatrzymuje dzialajacego sterownika jadra. Nieznana usluga Xen blokuje dalszy etap.
9. Po usunieciu uslug wymaga restartu. Dopiero potem kopiuje, hashuje i usuwa
   rozpoznane pozostalosci SYS z System32\drivers. Weryfikuje CompanyName pliku.
10. Przed skasowaniem SYS sprawdza odwolania uslug we wszystkich ControlSetNNN.
    Pozostale odwolanie, takze w nieaktywnym zestawie, blokuje usuniecie. Skrypt NIE
    kasuje automatycznie uslug z nieaktywnych zestawow rejestru.

Kolejne uruchomienia ponownie odkrywaja stan. Nie ma obietnicy zakonczenia w jednym
przebiegu. Liczba restartow zalezy od instalatora, PnP i zastanych pozostalosci.

## 4. Uruchomienie krok po kroku

### 4.1. Najpierw walidacja parserem, bez uruchamiania skryptu

W Windows PowerShell 5.1 x64:

```powershell
$tokens = $null
$parseErrors = $null
$path = (Resolve-Path .\Remove-XenTools.ps1).Path
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $path, [ref]$tokens, [ref]$parseErrors
)
$parseErrors | Format-List Message, Extent
if ($parseErrors.Count -gt 0) { throw 'Nie uruchamiaj: bledy parsera.' }
```

Brak bledow parsera nie potwierdza poprawnosci P/Invoke, zgodnosci wersji Tools
ani bezpieczenstwa migracji. Nie obchodz firmowej polityki wykonywania skryptow.

### 4.2. Audyt na klonie VM zrodlowej

```powershell
powershell.exe -NoProfile -File .\Remove-XenTools.ps1 -Phase Audit
```

Sprawdz before.json, nazwe produktu, producenta i ProductCode. Nie kopiuj GUID
z przykladu: ponizej jest celowy placeholder, ktory trzeba zastapic.

### 4.3. Standardowa deinstalacja na Xen, jezeli wymaga tego procedura migracji

```powershell
powershell.exe -NoProfile -File .\Remove-XenTools.ps1 `
    -Phase Uninstall `
    -ProductCode '{GUID-Z-RAPORTU}' `
    -Execute -BackupConfirmed -AllowSourceUninstall
```

Po udanym produkcie: kontrolowany restart, audyt, nastepny produkt jezeli istnieje.
Nie podawaj listy wielu GUID z zalozeniem, ze zostana usuniete naraz: implementacja
celowo konczy przebieg po pierwszym udanym MSI. Dla instalatora EXE uzyj oficjalnej
procedury danej wersji; skrypt nie zgaduje parametrow cichej deinstalacji.

### 4.4. Konwersja i pierwszy start kopii na Hyper-V

Nie uruchamiaj jednoczesnie oryginalu i klonu z ta sama tozsamoscia w tej samej sieci.
Zweryfikuj generacje VM, tryb BIOS/UEFI, kontroler dysku systemowego, start systemu,
nowa karte sieciowa, adresacje i aplikacje. Ten skrypt nie konwertuje dyskow i nie
przenosi ustawien IP. Zapisz konfiguracje sieci przed deinstalacja.

### 4.5. Audyt i podglad czyszczenia na Hyper-V

```powershell
powershell.exe -NoProfile -File .\Remove-XenTools.ps1 -Phase Audit
powershell.exe -NoProfile -File .\Remove-XenTools.ps1 `
    -Phase Cleanup -Execute -BackupConfirmed -WhatIf
```

WhatIf zapisuje raporty i kompiluje pomocniczy typ C# w pamieci, ale nie uruchamia
MSI, nie usuwa urzadzen/pakietow/uslug/plikow i nie zmienia filtrow. Blokady wstepne
nadal obowiazuja. To nie jest symulacja wyniku deinstalacji ani gwarancja powodzenia.

### 4.6. Wlasciwe czyszczenie

```powershell
powershell.exe -NoProfile -File .\Remove-XenTools.ps1 `
    -Phase Cleanup -Execute -BackupConfirmed
$LASTEXITCODE
```

Potwierdzenia sa domyslnie wlaczone. Po sprawdzeniu planu mozna dodac -Confirm:$false.
Odmowa operacji zaleznosci moze zatrzymac dalszy etap; skrypt nie powinien wtedy
przechodzic do kasowania plikow.

- 0: audyt/WhatIf zakonczony lub brak pozostalosci w kontrolowanym zakresie.
- 1: blad lub blokada; czytaj transcript.txt i result.json, nie dodawaj /force.
- 3010: restart wymagany, potem ponow audyt i odpowiednia faze.

Zawsze uruchamiaj jako oddzielny proces powershell.exe -File. Skrypt konczy sie
instrukcja exit; nie uzywaj dot-sourcing (`. .\Remove-XenTools.ps1`).

## 5. Raporty i kopie

Domyslnie: C:\ProgramData\XenCleanup\<czas-identyfikator>.

- before.json: stan przed przebiegiem.
- after.json: stan po dojscu do konca fazy Cleanup; nie powstaje przy wczesnej blokadzie
  ani przy przerwaniu etapu wymagajacego restartu.
- result.json: kod, tryb i zdarzenia; moze nie powstac po wymuszonym restarcie/zabiciu procesu.
- transcript.txt: komunikaty i wyjscie narzedzi.
- msi-*.log: log konkretnej deinstalacji.
- oemNN.inf/: wyeksportowany pakiet przed usunieciem.
- *.reg: kopie zmienianych kluczy filtrow i uslug.
- *.sys i deleted-file-hashes.csv: kopie i SHA256 usuwanych plikow.
- restart-required.json w WorkRoot: znacznik restartu z czasem uruchomienia systemu.

Nie zmieniaj WorkRoot pomiedzy przebiegami i nie kasuj znacznika, aby obejsc restart.
Ogranicz dostep do katalogu: raporty zawieraja konfiguracje maszyny i sieciowych
urzadzen PnP. Skrypt nie ustawia niestandardowych ACL. Kopie w tym katalogu nie
zastepuja backupu calej VM i nie stanowia automatycznego rollbacku.

## 6. Znane ograniczenia i warunki zatrzymania

- Nie naprawia VM, ktora nie startuje na Hyper-V. Brak trybu offline/WinRE.
- Nie wykonuje pelnego czyszczenia na dzialajacym XenServer.
- Nie usuwa innych produktow Citrix, katalogow ProgramData\Citrix*, wszystkich ghost
  NIC, wszystkich urzadzen o statusie Unknown ani nieznanych plikow xen*.sys.
- Lista INF/SYS jest jawna i ograniczona. Nietypowe nazwy, provider lub CompanyName
  wymagaja analizy konkretnego pakietu. Nie rozszerzaj listy samym wildcardem.
- Filtry sa przeszukiwane w Control\Class, nie we wszystkich galeziach Enum.
  Filtry per-device, zaleznosci uslug i inne wpisy specyficzne dla wersji moga pozostac.
- Stare wpisy uslug w nieaktywnym ControlSet moga zablokowac finalne kasowanie SYS.
  Wymagana osobna ocena tych wpisow; brak automatycznego obchodzenia blokady.
- Brak automatycznej naprawy ACL, takeown, odblokowywania plikow i wymuszania usuniecia.
- Kontrola restartu obejmuje wybrane znaczniki Windows, nie wszystkie mozliwe instalatory.
- Pakiet w uzyciu lub sterownik w stanie Running powoduje blokade, nie wymuszone usuniecie.
- Blad po czesciowych zmianach nie cofa poprzednich operacji. Raportuj i ocen stan.
- Rozpoznanie platformy i listy sterownikow wymaga testu na rzeczywistych wersjach.
- Kod 0 w Audit nie oznacza czystej maszyny; oznacza udany audyt. Ocen before.json.

## 7. Minimalna macierz testow na klonie

1. Audit na Xen: brak zmian konfiguracji, kompletny before.json.
2. Cleanup na Xen: blokada przed pierwsza zmiana.
3. WhatIf na Hyper-V: brak zmian konfiguracji, raport i komunikaty planu.
4. Obecne urzadzenie Xen, takze disabled: blokada.
5. Ghost Xen i ghost innego producenta: usuniety tylko Xen.
6. UpperFilters = inny filtr + xenfilt: pozostaje inny filtr.
7. Odmowa usuniecia ghost/pakietu/filtra/uslugi: brak przejscia do niebezpiecznego etapu.
8. MSI 0/3010/blad: poprawny log, restart lub blokada; brak dalszego czyszczenia.
9. Pakiet w uzyciu: brak /force i brak kasowania SYS.
10. Dzialajacy sterownik jadra: blokada, brak StopService dla sterownika.
11. Nieznany provider/CompanyName lub stary ControlSet: blokada finalnego kasowania.
12. Ponowienie bez restartu: 3010; po restarcie: ponowne odkrycie stanu.
13. Po finalnym restarcie: start VM, dyski, siec/IP/DNS, aplikacje, log System,
    nowy backup i test odtworzenia. Powtorzony Audit nie wykrywa elementow w zakresie.

## 8. Odtworzenie

Najpewniejszy rollback to odtworzenie calego klonu/VM ze sprawdzonej kopii.
Nie importuj masowo wszystkich REG i nie kopiuj SYS do pracujacego systemu bez
analizy zgodnosci pakietu, filtrow i uslug. Sam eksport pakietu nie przywraca produktu
MSI ani konfiguracji PnP. Nie uruchamiaj zrodla i odtworzonej kopii jednoczesnie
w tej samej sieci.

## 9. Zrodla

[S1] James Kindon, Migrate XenServer VMs to HyperV, 2019-01-06:
https://jkindon.com/migrate-xenserver-vms-to-hyperv/

[S2] mmartinez, removeGhost.ps1, kod wskazany przez uzytkownika:
https://gist.github.com/mmartinez/f7d73198f8f8baed006c8653326fe770

[S3] rbicelli, xenserver-tools-remover.ps1, kod wskazany przez uzytkownika:
https://github.com/rbicelli/xenserver-tools-remover/blob/main/xenserver-tools-remover.ps1

[S4] Microsoft Learn, PnPUtil Command Syntax:
https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax
W szczegolnosci: /delete-driver i /export-driver od Windows 10 1607;
/remove-device od Windows 10 2004. Dlatego usuwanie urzadzen realizuje SetupAPI.

[S5] Microsoft Learn, DIF_REMOVE i SetupDiCallClassInstaller:
https://learn.microsoft.com/en-us/windows-hardware/drivers/install/dif-remove
https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupdicallclassinstaller
https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupdigetdeviceinstallparamsw

[S6] Microsoft Learn, Working with software installations:
https://learn.microsoft.com/en-us/powershell/scripting/samples/working-with-software-installations?view=powershell-7.6

Materialy publiczne odczytane podczas przygotowania odpowiedzi. Nie korzystano
z danych firmowych ani nie wykonywano operacji na serwerach uzytkownika.
