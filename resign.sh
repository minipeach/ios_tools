#!/bin/bash
# ipa文件，entitlements.plist，embedded.mobileprovision 请放同一目录下
# 该脚本已包含了entitlements.plist的自动生成
# 通过security find-identity -p codesigning -v 查看证书
# 通过codesign -dvvv Payload/xxx.app 查看签名信息

if ! ([ -f "$1" ]); then
  echo "\"${1}\" 文件不存在"
  exit 1
fi

ipaName=${1%.ipa}
if [ "$ipaName" = "$1" ]; then
  echo "\"${1}\" 不是 ipa 文件"
  exit 1
fi

# 初始化变量
filename=""
name=""
id=""

# 获取第一个位置参数，即文件名
if [ $# -gt 0 ]; then
    filename=$1
    shift 
fi


while [ "$#" -gt 0 ]; do
    case $1 in
        -name)
            if [ "$2" ]; then
                name=$2
                shift 2 
            else
                echo "Error: -name requires a value."
                exit 1
            fi
            ;;
        -id)
            if [ "$2" ]; then
                id=$2
                shift 2
            else
                echo "Error: -id requires a value."
                exit 1
            fi
            ;;
        *)
            echo "Unknown parameter passed: $1"
            exit 1
            ;;
    esac
done


cert="Apple Development: XXX XXX (9HXXXXXXXX)"

ipaFilePath=$(realpath "$filename")  
echo "IPA 文件路径是：$ipaFilePath"

path=$(dirname "$ipaFilePath")
echo "IPA 文件目录是：$path"

ipaFileName=$(basename "$ipaFilePath" .ipa)
echo "IPA 文件名称是：$ipaFileName"

resignPath=${path}/${ipaFileName}
echo "IPA resign目录是：$resignPath"

## Step 1: 解压 IPA 文件
unzip -q -o $ipaFilePath -d $resignPath

appDir=$(ls -d ${resignPath}/Payload/*.app | head -n 1)


# 判断是否找到了 .app 文件夹
if [ -n "$appDir" ]; then
  echo "appDir 目录是：$appDir"
else
  echo "没有找到 .app 目录"
  exit 1
fi


## Step 2: 移除旧的签名，移除PlugIns/Watch目录(可选)，如不移除则需要签名
rm -rf ${appDir}/_CodeSignature/
rm -rf ${appDir}/CodeResources
rm -rf ${appDir}/PlugIns
rm -rf ${appDir}/Watch


## Step 3: 复制新的 Provisioning Profile，生成entitlements文件
cp "${path}/embedded.mobileprovision" "${appDir}/"
security cms -D -i ${path}/embedded.mobileprovision > ${path}/profile.plist
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' ${path}/profile.plist > ${path}/entitlements.plist


## Step 4: 对 Framework 和动态库进行签名
echo "签名 Frameworks..."

find "$appDir" -type d -name "*.framework" | while read -r framework; do
  echo "Found framework: $framework"
  /usr/bin/codesign -f -s "${cert}" --entitlements ${path}/entitlements.plist "$framework"
  if [ $? -ne 0 ]; then
    echo "签名失败：$framework"
    exit 1
  fi
done

echo "签名 appex..."

find "$appDir" -type d -name "*.appex" | while read -r appex; do
  echo "Found appex: $appex"
  /usr/bin/codesign -f -s "${cert}" --entitlements ${path}/entitlements.plist "$appex"
  if [ $? -ne 0 ]; then
    echo "签名失败：$appex"
    exit 1
  fi
  cp "${path}/embedded.mobileprovision" "${appex}"
done

echo "签名 dylib..."

find "$appDir" -type f -name "*.dylib" | while read -r dylib; do
  echo "Found dylib: $dylib"
  /usr/bin/codesign -f -s "${cert}" --entitlements ${path}/entitlements.plist "$dylib"
  if [ $? -ne 0 ]; then
    echo "签名失败：$dylib"
    exit 1
  fi
done


# if [ -d "${appDir}/Frameworks" ]; then
#   for framework in ${appDir}/Frameworks/*.framework; do
#     if [ -n "$framework" ]; then
#       echo "签名 -> ${framework}"
#       /usr/bin/codesign -f -s "" --entitlements entitlements.plist "$framework"
#       if [ $? -ne 0 ]; then
#         echo "签名失败：$framework"
#         exit 1
#       fi
#     fi
#   done

#   for dylib in ${appDir}/Frameworks/*.dylib; do
#     if [ -f "$dylib" ]; then
#       echo "签名 -> ${dylib}"
#       /usr/bin/codesign -f -s "Apple Development: JiaHong Xu (9HREN3LD7L)" --entitlements entitlements.plist "$dylib"
#       if [ $? -ne 0 ]; then
#         echo "签名失败：$dylib"
#         exit 1
#       fi
#     fi
#   done
# fi


#   for dylib in ${appDir}/iPatchDylibs/*.dylib; do
#     if [ -f "$dylib" ]; then
#       echo "签名 -> ${dylib}"
#       /usr/bin/codesign -f -s "Apple Development: JiaHong Xu (9HREN3LD7L)" --entitlements entitlements.plist "$dylib"
#       if [ $? -ne 0 ]; then
#         echo "签名失败：$dylib"
#         exit 1
#       fi
#     fi
#   done


# Step 5: 对主应用进行签名

#可选
#defaults write ${appDir}/Info CFBundleDisplayName "hello"
#defaults write ${appDir}/Info CFBundleIdentifier "com.peach.test"

if [ "$name" ]; then
  defaults write ${appDir}/Info CFBundleDisplayName "$name"
fi

if [ "$id" ]; then
  defaults write ${appDir}/Info CFBundleIdentifier "$id"
fi



echo "签名主应用..."
/usr/bin/codesign -f -s "${cert}" --entitlements ${path}/entitlements.plist "${appDir}"
if [ $? -ne 0 ]; then
  echo "主应用签名失败"
  exit 1
fi


# Step 6: 打包新的 IPA
#此处必须cd进去执行zip，否则无法安装
cd $resignPath
zip -q -r ${path}/${ipaFileName}New.ipa Payload/
if [ $? -eq 0 ]; then
  echo "重新签名的 IPA 已成功打包：${ipaFileName}New.ipa"
  #rm -rf ${resignPath}
else
  echo "打包失败"
  exit 1
fi
