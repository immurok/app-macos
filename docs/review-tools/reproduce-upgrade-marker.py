from pathlib import Path
import tempfile, subprocess, os, argparse
parser = argparse.ArgumentParser(description="Review-only reproduction for PR #21's marker protocol; all mutations use temporary fixtures.")
parser.add_argument("script", type=Path, help="Path to PR #21's uninstall-postinstall at 67de871")
script = parser.parse_args().script.resolve()
if not script.is_file():
 parser.error("uninstall script does not exist")
for case in ['regular','symlink','directory','absent']:
 with tempfile.TemporaryDirectory(prefix='immurok-review-') as tmp:
  r=Path(tmp)
  for p in ['etc/pam.d','etc/immurok/pam','usr/local/bin','usr/local/lib/pam','home/.immurok','Applications/immurok.app','tmp']:(r/p).mkdir(parents=True)
  (r/'etc/pam.d/authorization').write_text('auth sufficient /usr/local/lib/pam/pam_immurok.so\nauth required pam_opendirectory.so\n')
  (r/'etc/immurok/pam/501.key').write_bytes(b'K'*32)
  (r/'usr/local/bin/imk').touch()
  marker=r/'tmp/immurok-keep-user-data'
  if case=='regular':marker.touch()
  if case=='symlink':
   target=r/'target';target.touch();marker.symlink_to(target)
  if case=='directory':marker.mkdir()
  # Companion cask uses touch then unconditionally execs the installer.
  if case!='absent':subprocess.run(['touch',str(marker)],check=True)
  result=subprocess.run(['bash',str(script)],env={**os.environ,'IMMUROK_ROOT':str(r)},capture_output=True,text=True)
  print(f'{case}: exit={result.returncode}, key_preserved={(r/"etc/immurok/pam/501.key").exists()}, marker_remaining={marker.exists()}')
