#!/bin/bash
CWD=`dirname "$(readlink -f "$0")"`

DOWNLOADSERVER=${DOWNLOADSERVER:--1}
GAMEENGINE=${GAMEENGINE:--1}
PASSWORD=${PASSWORD:-}
CURRENTVERSION=${CURRENTVERSION:--1}
ASKBEFOREUPDATING=${ASKBEFOREUPDATING:--1}
UPDATERVERSION=${UPDATERVERSION:-4.0.3}
APIURL="http://www.urbanterror.info/api/updaterv4/"
URT_GAME_SUBDIR=${URT_GAME_SUBDIR:-q3ut4}
BROWSER=${BROWSER:-}

if [ -z "$PLATFORM" ]; then
    if [ "$(uname -m)" == "x86_64" ]; then
        PLATFORM=Linux64
    else
        PLATFORM=Linux32
    fi
fi

XMLLINT=${XMLLINT:-`which xmllint`}
CURL=${CURL:-`which curl`}
if [ -z "$BROWSER" ]; then
    if which lynx >/dev/null 2>&1 ; then
        BROWSER=`which lynx`
    elif which links >/dev/null 2>&1 ; then
        BROWSER=`which links`
    elif which elinks >/dev/null 2>&1 ; then
        BROWSER=`which elinks`
    fi
fi

if [ ! -x "$XMLLINT" ]; then
    echo "ERROR: xmllint not found. Install xmllint (part of libxml2, often split off as libxml2-utils or similar) or specify its location by passing XMLLINT=/path/to/xmllint to this script." 1>&2
    exit 1
fi
if [ ! -x "$CURL" ]; then
    echo "ERROR: curl not found. Install curl or specify its location by passing CURL=/path/to/curl to this script." 1>&2
    exit 2
fi

# Connect to the API and parse the result.
# Pass the query as the first argument (all others are ignored),
# eg. "versionInfo" or "versionFiles"
function doManifest ()
{
    local manifest=$($CURL -X POST -H "Content-Type: application/x-www-form-urlencoded;charset=utf-8" -d "platform=${PLATFORM}" -d "query=$1" -d "password=${PASSWORD}" -d "version=${CURRENTVERSION}" -d "engine=${GAMEENGINE}" -d "server=${DOWNLOADSERVER}" -d "updaterVersion=${UPDATERVERSION}" $curlOpts "$APIURL")

    if [ -z "$manifest" ]; then
        echo "ERROR: Failed to connect to API" 1>&2
        exit 3
    fi

    apiVersion=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/APIVersion/text())" - )
    changelog=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/Changelog/text())" - )
    licenceText=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/Licence/text())" - )

    newsList="<html><head><title>Urban Terror News</title></head><body style=\"background-color: black;\">"
    for i in `seq $(echo "$manifest" | $XMLLINT --xpath "count(/Updater/NewsList/NewsText)" - )`
    do
        newsList="${newsList}<br />
$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/NewsList/NewsText[$i]/text())" - )"
    done
    newsList="${newsList}</body></html>"

    serverCount=0
    unset serverName
    unset serverURL
    unset serverLocation
    unset serverId
    for i in `seq $(echo "$manifest" | $XMLLINT --xpath "count(/Updater/ServerList/Server)" - )`
    do
        serverCount=$((${serverCount}+1))
        serverName[$serverCount]=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/ServerList/Server[$i]/ServerName/text())" - )
        serverURL[$serverCount]=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/ServerList/Server[$i]/ServerURL/text())" - )
        serverLocation[$serverCount]=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/ServerList/Server[$i]/ServerLocation/text())" - )
        serverId[$serverCount]=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/ServerList/Server[$i]/ServerId/text())" - )
    done

    engineCount=0
    unset engineName
    unset engineDir
    unset engineId
    unset engineLaunchString
    for i in `seq $(echo "$manifest" | $XMLLINT --xpath "count(/Updater/EngineList/Engine)" - )`
    do
        engineCount=$((${engineCount}+1))
        engineName[$engineCount]=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/EngineList/Engine[$i]/EngineName/text())" - )
        engineDir[$engineCount]=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/EngineList/Engine[$i]/EngineDir/text())" - )
        engineId[$engineCount]=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/EngineList/Engine[$i]/EngineId/text())" - )
        engineLaunchString[$engineCount]=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/EngineList/Engine[$i]/EngineLaunchString/text())" - )
    done

    versionCount=0
    unset versionName
    unset versionId
    for i in `seq $(echo "$manifest" | $XMLLINT --xpath "count(/Updater/VersionList/Version)" - )`
    do
        versionCount=$((${versionCount}+1))
        versionName[$versionCount]=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/VersionList/Version[$i]/VersionName/text())" - )
        versionId[$versionCount]=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/VersionList/Version[$i]/VersionNumber/text())" - )
    done

    fileCount=0
    local mustDownload
    unset filePath
    unset fileName
    unset fileMd5
    unset fileSize
    unset fileUrl
    unset packsList
    # There can be multiple Files sections (one for zUrT_*.pk3 and one for
    # the engine) so use nested loops
    for i in `seq $(echo "$manifest" | $XMLLINT --xpath "count(/Updater/Files)" - )`
    do
        for j in `seq $(echo "$manifest" | $XMLLINT --xpath "count(/Updater/Files[$i]/File)" - )`
        do
            tmpFileDir=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/Files[$i]/File[$j]/FileDir/text())" - )
            tmpFileName=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/Files[$i]/File[$j]/FileName/text())" - )
            tmpFileMD5=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/Files[$i]/File[$j]/FileMD5/text())" - )
            tmpFileSize=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/Files[$i]/File[$j]/FileSize/text())" - )
            tmpFileUrl=$(echo "$manifest" | $XMLLINT --xpath "string(/Updater/Files[$i]/File[$j]/FileUrl[last()]/text())" - )

            mustDownload=0

            if [ -n "$tmpFileName" ]; then
                # If file does not exist, download
                if ! [ -e "${CWD}/${tmpFileDir}/${tmpFileName}" ]; then
                    mustDownload=1
                # If wrong MD5, download
                elif ! echo "${tmpFileMD5}  ${CWD}/${tmpFileDir}/${tmpFileName}" | md5sum -c >/dev/null 2>&1 ; then
                    mustDownload=1
                fi
                # Empty MD5 = delete this file
                if [ -z "$tmpFileMD5" ]; then
                    rm -f "${CWD}/${tmpFileDir}/${tmpFileName}"
                    mustDownload=0
                fi
                packsList[$((${#packsList[*]}+1))]="$tmpFileName"
            fi

            if [ $mustDownload -eq 1 ]; then
                fileCount=$((${fileCount}+1))
                filePath[$fileCount]="$tmpFileDir"
                fileName[$fileCount]="$tmpFileName"
                fileMd5[$fileCount]="$tmpFileMD5"
                fileSize[$fileCount]="$tmpFileSize"
                fileUrl[$fileCount]="$tmpFileUrl"
            fi
        done
    done
}

function checkAPIVersion ()
{
    if [ "$apiVersion" != "$UPDATERVERSION" ]; then
        echo "ERROR: This version (${UPDATERVERSION}) of the Updater is outdated. Please download the new Updater here: http://get.urbanterror.info" 1>&2
        exit 4
    fi
}

function apiError ()
{
    echo "ERROR: Information from the API is missing or wrong. Please report it on www.urbanterror.info and try again later." 1>&2
    exit 5
}

function checkDownloadServer ()
{
    if [ $serverCount -lt 1 ]; then
        apiError
    fi

    local found=0
    for i in `seq $serverCount`
    do
        if [ -n "${serverId[$i]}" -a "$DOWNLOADSERVER" == "${serverId[$i]}" ]; then
            found=1
            break
        fi
    done

    if [ $found -ne 1 ]; then
        DOWNLOADSERVER=${serverId[1]}
    fi
}

function checkGameEngine ()
{
    if [ $engineCount -lt 1 ]; then
        apiError
    fi

    local found=0
    for i in `seq $engineCount`
    do
        if [ -n "${engineId[$i]}" -a "$GAMEENGINE" == "${engineId[$i]}" ]; then
            found=1
            break
        fi
    done

    if [ $found -ne 1 ]; then
        GAMEENGINE=${engineId[1]}
    fi
}

function checkVersion ()
{
    if [ $versionCount -lt 1 ]; then
        apiError
    fi

    local found=0
    for i in `seq $versionCount`
    do
        if [ -n "${versionId[$i]}" -a "$CURRENTVERSION" == "${versionId[$i]}" ]; then
            found=1
            break
        fi
    done

    if [ $found -ne 1 ]; then
        CURRENTVERSION=${versionId[1]}
    fi
}

function checkFiles ()
{
    local found
    if [ ${#packsList[*]} -gt 0 ]; then
        if [ -d "${CWD}/${URT_GAME_SUBDIR}" ]; then
            cd "${CWD}/${URT_GAME_SUBDIR}"
            for i in zUrT*.pk3
            do
                if [ "$i" == "zUrT*.pk3" ]; then
                    break
                fi
                found=0
                for j in `seq ${#packsList[*]}`
                do
                    if [ "${packsList[$j]}" == "$i" ]; then
                        found=1
                        break
                    fi
                done
                if [ $found -eq 0 ]; then
                    rm -f "$i"
                fi
            done
        fi
    fi
    cd "${CWD}"
}

function downloadFiles ()
{
    local errored=0
    if [ $fileCount -eq 0 ]; then
        if [ $runQuiet -eq 0 ]; then
            echo 'Your game is up to date!'
        fi
        playGame
    else
        if [ $ASKBEFOREUPDATING -eq 1 -a $runQuiet -eq 0 ]; then
            read -p "A new update is available. Would you like to download it now? [y/n]: " -e INPUT
            if [ "$INPUT" != "y" -a "$INPUT" != "Y" ]; then
                echo 'Update cancelled - your game is outdated!'
                playGame
                return
            fi
        fi
        for i in `seq $fileCount`
        do
            cd "${CWD}/${filePath[$i]}" || exit 6
            if [ -n "${fileUrl[$i]}" -a -n "${fileName[$i]}" ]; then
                $CURL $curlOpts "${fileUrl[$i]}" -o "${fileName[$i]}"
                if ! echo "${fileMd5[$i]}  ${fileName[$i]}" | md5sum -c >/dev/null 2>&1 ; then
                    echo "ERROR: Downloaded file (${fileName[$i]}) is corrupt\! Re-run this updater to try again..." 1>&2
                    errored=1
                    rm -f "${fileName[$i]}"
                fi
                if [[ "${fileName[$i]}" =~ .*\.i386.* ]] || [[ "${fileName[$i]}" =~ .*\.x86_64.* ]]; then
                    chmod +x "${fileName[$i]}"
                fi
            else
                apiError
            fi
        done
        cd "${CWD}"
        if [ $errored -eq 1 ]; then
            echo "ERROR: Some downloaded files were corrupt. Re-run the updater to try again." 1>&2
            exit 7
        fi
        if [ $runQuiet -eq 0 ]; then
            echo 'Your game is now up to date!'
        fi
    fi
}

runQuiet=1

doManifest "versionInfo"
checkAPIVersion
checkDownloadServer
checkGameEngine
checkVersion

if [ ! -d "${CWD}/${URT_GAME_SUBDIR}" ]; then
    mkdir "${CWD}/${URT_GAME_SUBDIR}"
fi

doManifest "versionFiles"
checkAPIVersion
checkDownloadServer
checkGameEngine
checkVersion
checkFiles
downloadFiles
