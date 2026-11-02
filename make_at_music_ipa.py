import os
import shutil
import zipfile
import glob

# 查找用户目录下的 DerivedData/ATMusic-*/Build/Products/*-iphoneos/ATMusic.app
home = os.path.expanduser("~")
search_pattern = os.path.join(home, "Library/Developer/Xcode/DerivedData", "ATMusic-*", "Build/Products", "*-iphoneos", "ATMusic.app")
candidates = glob.glob(search_pattern)

current_dir = os.path.dirname(os.path.abspath(__file__))
ipa_output = os.path.join(current_dir, "AT-Music.ipa")

if not candidates:
    # 尝试在整个 DerivedData 查找
    search_all = glob.glob(os.path.join(home, "Library/Developer/Xcode/DerivedData", "**", "ATMusic.app"), recursive=True)
    candidates = [c for c in search_all if "iphoneos" in c]

if not candidates:
    print("NO_APP_FOUND")
else:
    # 取最新的一个
    candidates.sort(key=lambda x: os.path.getmtime(x), reverse=True)
    app_path = candidates[0]
    print(f"FOUND_APP: {app_path}")
    
    payload_dir = os.path.join(current_dir, "Payload")
    if os.path.exists(payload_dir):
        shutil.rmtree(payload_dir)
    os.makedirs(payload_dir)
    
    dest_app = os.path.join(payload_dir, "ATMusic.app")
    shutil.copytree(app_path, dest_app)
    
    # 压缩为 ipa
    if os.path.exists(ipa_output):
        os.remove(ipa_output)
        
    with zipfile.ZipFile(ipa_output, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk(payload_dir):
            for file in files:
                file_path = os.path.join(root, file)
                arcname = os.path.relpath(file_path, current_dir)
                zipf.write(file_path, arcname)
                
    shutil.rmtree(payload_dir)
    print(f"SUCCESS: {ipa_output}")
