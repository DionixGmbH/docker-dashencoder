#!/bin/bash

# settings for encoding, should encoding be necessary, i.e. should the input file not be in MPEG-4 container format or
# should the video track not be H264 encoded
PRESET=${PRESET:-"slow"}
BITRATE=${BITRATE:-2400}
MAXBITRATE=${MAXBITRATE:-4800}
BUFFERSIZE=${BUFFERSIZE:-9600}
MINKEYINT=${MINKEYINT:-48}
KEYINT=${KEYINT:-48}
PASS=${PASS:-1}
PROFILE=${PROFILE:-"main"}
LEVEL=${LEVEL:-"5.2"}
LEVELS=${1:-""}

# change to the output directory
cd /output/

# make sure special file names containing the special characters space or tab are kept together
IFS="
"
# loop all files in the input directory
for file in $(ls /input/)
do
	# get the current input file's name without file name suffix
	name=${file%.*}
	
	# get metainformation for the current input file
	mediainfo --Output=XML "/input/$file" > ${name}.xml
	
	# extract specific metainformation
	containerFormat=$(xml-strings ${name}.xml :/Mediainfo/File/track[1]/Format)
	width=$(xml-strings ${name}.xml :/Mediainfo/File/track[2]/Width | grep -o "^[0-9]*")
	height=$(xml-strings ${name}.xml :/Mediainfo/File/track[2]/Height | grep -o "^[0-9]*")
	fps=$(xml-strings ${name}.xml :/Mediainfo/File/track[2]/Frame_rate | grep -o "^[0-9.]*")
	
	# check if the current input file is not in MPEG-4 container format
	if [ $containerFormat != "MPEG-4" ]
	then
		# re-encode the current input file's video track
		avconv -i "/input/$file" -an -vf format=yuv420p -f rawvideo - | \
		x264 --output "${name}.264" --fps $fps --preset $PRESET --bitrate $BITRATE --vbv-maxrate $MAXBITRATE \
			--vbv-bufsize $BUFFERSIZE --min-keyint $MINKEYINT --keyint $KEYINT --scenecut 0 --no-scenecut --pass $PASS \
			--profile $PROFILE --level $LEVEL --input-res "$width"x"$height" --stats /dev/null -
		
		# extract the current input file's audio track
		mplayer -dumpaudio -dumpfile "${name}.audio" "/input/$file"
	else
		# extract the current input file's video track
		MP4Box -single 1 -out "${name}.264" "/input/$file"
		# extract the current input file's audio track
		MP4Box -single 2 -out "${name}.audio" "/input/$file"
	fi
	        
	# add the video track to a new MPEG-4 container file
	MP4Box -add "${name}.264" -fps $fps "${name}-video.mp4"
	
	# add the audio track to a new MPEG-4 container file
	MP4Box -add "${name}.audio" -fps $fps "${name}-audio.mp4"
	# cleanup, remove the audio track file
	rm "${name}.audio"
    
    # dash the video file
	MP4Box -dash 10000 -frag 10000 -rap -dash-profile onDemand -segment-name "${name}-video_" "${name}-video.mp4"
	# dash the audio file
	MP4Box -dash 10000 -frag 10000 -rap -dash-profile onDemand -segment-name "${name}-audio_" "${name}-audio.mp4"
	
	# add the audio file's adaptation set to the video file's xml file
	xml-cp --append ${name}-audio_dash.mpd :/MPD/Period/AdaptationSet[1] ${name}-video_dash.mpd :/MPD/Period[1]/ | \
		xml-fmt > ${name}.mpd
	
	# levels are separated by comma
	IFS=","
	# loop all levels
	for level in $LEVELS
	do
		# get the current level's width
		scaledWidth=$(echo $level | cut -d x -f 1)
		# get the current level's height
		scaledHeight=$(echo $level | cut -d x -f 2 | cut -d @ -f 1)
		# get the current level's bitrate
		bitrate=$(echo $level | cut -d @ -f 2)
		
		# re-encode the current input file's video track
		avconv -i "/input/$file" -an \
			-vf format=yuv420p,scale=${scaledWidth}:${scaledHeight},crop=${scaledWidth}:${scaledHeight} -f rawvideo \
			- | \
		x264 --output "${name}-${level}.264" --fps $fps --preset $PRESET --bitrate $bitrate \
			--vbv-maxrate $((bitrate * 2)) --vbv-bufsize $BUFFERSIZE --min-keyint $MINKEYINT --keyint $KEYINT \
			--scenecut 0 --no-scenecut --pass $PASS --profile $PROFILE --level $LEVEL \
			--input-res "$scaledWidth"x"$scaledHeight" --stats /dev/null -
			
		# add the current level's video track to a new MPEG-4 container file
		MP4Box -add "${name}-${level}.264" -fps $fps "${name}-${level}-video.mp4"
		# cleanup, remove the video track file
		rm "${name}-${level}.264"
		
		# dash the curent level's video file
		MP4Box -dash 10000 -frag 10000 -rap -dash-profile onDemand -segment-name "${name}-${level}-video_" \
			"${name}-${level}-video.mp4"
			
		# add the current level's video file's representation to the video file's xml file
		xml-cp --append ${name}-${level}-video_dash.mpd :/MPD/Period/AdaptationSet[1]/Representation[1] ${name}.mpd \
			:/MPD/Period[1]/AdaptationSet[1]/ | xml-fmt > ${name}-${level}.mpd && mv ${name}-${level}.mpd ${name}.mpd
			
		# cleanup, remove the current level's mpd file
		rm ${name}-${level}-video_dash.mpd
	done
	
	# cleanup, remove the video track file
	rm "${name}.264"
	# cleanup, remove the metainformation file
	rm "${name}.xml"
done

exit 0