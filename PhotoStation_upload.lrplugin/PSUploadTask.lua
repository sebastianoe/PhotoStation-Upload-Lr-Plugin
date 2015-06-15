--[[----------------------------------------------------------------------------

PSUploadTask.lua
Upload photos to Synology PhotoStation via HTTP(S) WebService
Copyright(c) 2015, Martin Messmer

This file is part of PhotoStation Upload - Lightroom plugin.

PhotoStation Upload is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

PhotoStation Upload is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with PhotoStation Upload.  If not, see <http://www.gnu.org/licenses/>.

PhotoStation Upload uses the following free software to do its job:
	- convert.exe,			see: http://www.imagemagick.org/
	- ffmpeg.exe, 			see: https://www.ffmpeg.org/
	- qt-faststart.exe, 	see: http://multimedia.cx/eggs/improving-qt-faststart/

This code is derived from the Lr SDK FTP Upload sample code. Copyright: see below
--------------------------------------------------------------------------------

ADOBE SYSTEMS INCORPORATED
 Copyright 2007 Adobe Systems Incorporated
 All Rights Reserved.

NOTICE: Adobe permits you to use, modify, and distribute this file in accordance
with the terms of the Adobe license agreement accompanying it. If you have received
this file from a source other than Adobe, then your use, modification, or distribution
of it requires the prior written permission of Adobe.

------------------------------------------------------------------------------]]


-- Lightroom API
local LrApplication = import 'LrApplication'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
-- local LrProgressScope = import 'LrProgressScope'
local LrShell = import 'LrShell'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

require "PSUtilities"
require "PSConvert"
require "PSUpdate"
require "PSUploadAPI"
require "PSFileStationAPI"		-- publish only

local tmpdir = LrPathUtils.getStandardFilePath("temp")

--============================================================================--

PSUploadTask = {}

------------- getDateTimeOriginal -------------------------------------------------------------------

-- getDateTimeOriginal(srcFilename, srcPhoto)
-- get the DateTimeOriginal (capture date) of a photo or whatever comes close to it
-- tries various methods to get the info including Lr metadata, exiftool (if enabled), file infos
-- returns a unix timestamp and a boolean indicating if we found a real DateTimeOrig
function getDateTimeOriginal(srcFilename, srcPhoto)
	local srcDateTime = nil
	local isOrigDateTime = false
	
	if srcPhoto:getRawMetadata("dateTimeOriginal") then
		srcDateTime = srcPhoto:getRawMetadata("dateTimeOriginal")
		isOrigDateTime = true
		writeLogfile(3, "  dateTimeOriginal: " .. LrDate.timeToUserFormat(srcDateTime, "%Y-%m-%d %H:%M:%S", false ) .. "\n")
	elseif srcPhoto:getRawMetadata("dateTimeOriginalISO8601") then
		srcDateTime = srcPhoto:getRawMetadata("dateTimeOriginalISO8601")
		isOrigDateTime = true
		writeLogfile(3, "  dateTimeOriginalISO8601: " .. LrDate.timeToUserFormat(srcDateTime, "%Y-%m-%d %H:%M:%S", false ) .. "\n")
	elseif srcPhoto:getRawMetadata("dateTimeDigitized") then
		srcDateTime = srcPhoto:getRawMetadata("dateTimeDigitized")
		writeLogfile(3, "  dateTimeDigitized: " .. LrDate.timeToUserFormat(srcDateTime, "%Y-%m-%d %H:%M:%S", false ) .. "\n")
	elseif srcPhoto:getRawMetadata("dateTimeDigitizedISO8601") then
		srcDateTime = srcPhoto:getRawMetadata("dateTimeDigitizedISO8601")
		writeLogfile(3, "  dateTimeDigitizedISO8601: " .. LrDate.timeToUserFormat(srcDateTime, "%Y-%m-%d %H:%M:%S", false ) .. "\n")
	elseif srcPhoto:getFormattedMetadata("dateCreated") and srcPhoto:getFormattedMetadata("dateCreated") ~= '' then
		local srcDateTimeStr = srcPhoto:getFormattedMetadata("dateCreated")
		local year,month,day,hour,minute,second,tzone
		local foundDate = false -- avoid empty dateCreated
		
		-- iptcDateCreated: date is mandatory, time as whole, seconds and timezone may or may not be present
		for year,month,day,hour,minute,second,tzone in string.gmatch(srcDateTimeStr, "(%d+)-(%d+)-(%d+)T*(%d*):*(%d*):*(%d*)Z*(%w*)") do
			writeLogfile(4, string.format("dateCreated: %s Year: %s Month: %s Day: %s Hour: %s Minute: %s Second: %s Zone: %s\n",
											srcDateTimeStr, year, month, day, ifnil(hour, "00"), ifnil(minute, "00"), ifnil(second, "00"), ifnil(tzone, "local")))
			srcDateTime = LrDate.timeFromComponents(tonumber(year), tonumber(month), tonumber(day),
													tonumber(ifnil(hour, "0")),
													tonumber(ifnil(minute, "0")),
													tonumber(ifnil(second, "0")),
													iif(not tzone or tzone == "", "local", tzone))
			foundDate = true
		end
		if foundDate then writeLogfile(3, "  dateCreated: " .. LrDate.timeToUserFormat(srcDateTime, "%Y-%m-%d %H:%M:%S", false ) .. "\n") end
	
	-- dateTime is typically the date of the Lightroom import --> worst choice
--[[ 
	elseif srcPhoto:getRawMetadata("dateTime") then
		srcDateTime = srcPhoto:getRawMetadata("dateTime")
		writeLogfile(3, "  RawMetadate datetime\n")
		writeLogfile(3, "  dateTime: " .. LrDate.timeToUserFormat(srcDateTime, "%Y-%m-%d %H:%M:%S", false ) .. "\n")
]]
	end
	
	-- if nothing found in srcPhoto: take the fileCreationDate
	if not srcDateTime then
		local fileAttr = LrFileUtils.fileAttributes( srcFilename )
--		srcDateTime = exiftoolGetDateTimeOrg(srcFilename)
--		if srcDateTime then 
--			writeLogfile(3, "  exiftoolDateTimeOrg: " .. LrDate.timeToUserFormat(srcDateTime, "%Y-%m-%d %H:%M:%S", false ) .. "\n")
--		elseif fileAttr["fileCreationDate"] then
		if fileAttr["fileCreationDate"] then
			srcDateTime = fileAttr["fileCreationDate"]
			writeLogfile(3, "  fileCreationDate: " .. LrDate.timeToUserFormat(srcDateTime, "%Y-%m-%d %H:%M:%S", false ) .. "\n")
--[[
]]
		else
			srcDateTime = LrDate.currentTime()
			writeLogfile(3, "  no date found, using current date: " .. LrDate.timeToUserFormat(srcDateTime, "%Y-%m-%d %H:%M:%S", false ) .. "\n")
		end
	end
	return LrDate.timeToPosixDate(srcDateTime), isOrigDateTime
end

-----------------

-- function getPublishPath(srcPhotoPath, srcPhoto, renderedPhotoPath, exportParams) 
-- 	return relative local path of the srcPhoto and destination path of the rendered photo: remotePath = dstRoot + (localpath - srcRoot), 
--	returns:
-- 		localPath - relative local path as unix-path
-- 		remotePath - absolute remote path as unix-path
function getPublishPath(srcPhotoPath, srcPhoto, renderedPhotoPath, exportParams) 
	local localRenderedPath
	local localPath
	local remotePath
	
	-- if is virtual copy: add last three characters of photoId as suffix to filename
	if srcPhoto:getRawMetadata('isVirtualCopy') then
		srcPhotoPath = LrPathUtils.addExtension(LrPathUtils.removeExtension(srcPhotoPath) .. '-' .. string.sub(srcPhoto:getRawMetadata('uuid'), -3), 
												LrPathUtils.extension(srcPhotoPath))
		writeLogfile(3, 'isVirtualCopy: new srcPhotoPath is: ' .. srcPhotoPath .. '"\n')				
	end
	localRenderedPath = srcPhotoPath
			
	-- extension for published photo may differ from orgPhoto (e.g. RAW, DNG)
	-- use extension of renderedPhotoPath instead, if available
	if renderedPhotoPath ~= nil then
		localRenderedPath = LrPathUtils.addExtension(LrPathUtils.removeExtension(srcPhotoPath), LrPathUtils.extension(renderedPhotoPath))
	end

	if exportParams.copyTree then
		localPath = string.gsub(LrPathUtils.makeRelative(srcPhotoPath, exportParams.srcRoot), "\\", "/")
		localRenderedPath = string.gsub(LrPathUtils.makeRelative(localRenderedPath, exportParams.srcRoot), "\\", "/")
	else
		localPath = LrPathUtils.leafName(srcPhotoPath)
		localRenderedPath = LrPathUtils.leafName(localRenderedPath)
	end
	remotePath = iif(exportParams.dstRoot ~= '', exportParams.dstRoot .. '/' .. localRenderedPath, localRenderedPath)
	return localPath, remotePath
end
-----------------

-- function createTree(srcDir, srcRoot, dstRoot, dirsCreated, readOnly) 
-- 	derive destination folder: dstDir = dstRoot + (srcRoot - srcDir), 
--	create each folder recursively if not already created
-- 	store created directories in dirsCreated
-- 	return created dstDir or nil on error
function createTree(srcDir, srcRoot, dstRoot, dirsCreated, readOnly) 
	writeLogfile(4, "  createTree: Src Path: " .. srcDir .. " from: " .. srcRoot .. " to: " .. dstRoot .. "\n")

	-- sanitize srcRoot: avoid trailing slash and backslash
	local lastchar = string.sub(srcRoot, string.len(srcRoot))
	if lastchar == "/" or lastchar == "\\" then srcRoot = string.sub(srcRoot, 1, string.len(srcRoot) - 1) end

	-- check if picture source path is below the specified local root directory
	local subDirStartPos, subDirEndPos = string.find(string.lower(srcDir), string.lower(srcRoot))
	if subDirStartPos ~= 1 then
		writeLogfile(1, "  createTree: " .. srcDir .. " is not a subdir of " .. srcRoot .. "\n")
		return nil
	end

	-- Valid subdir: now recurse the destination path and create directories if not already done
	-- replace possible Win '\\' in path
	local dstDirRel = string.gsub(string.sub(srcDir, subDirEndPos+2), "\\", "/")

	-- sanitize dstRoot: avoid trailing slash
	if string.sub(dstRoot, string.len(dstRoot)) == "/" then dstRoot = string.sub(dstRoot, 1, string.len(dstRoot) - 1) end
	local dstDir = dstRoot .."/" .. dstDirRel

	writeLogfile(4,"  createTree: dstDir is: " .. dstDir .. "\n")
	
	local parentDir = dstRoot
	local restDir = dstDirRel
	
	while restDir do
		local slashPos = ifnil(string.find(restDir,"/"), 0)
		local newDir = string.sub(restDir,1, slashPos-1)
		local newPath = parentDir .. "/" .. newDir

		if not dirsCreated[newPath] then
			writeLogfile(2,"Create dir - parent: " .. parentDir .. " newDir: " .. newDir .. " newPath: " .. newPath .. "\n")
			
			local paramParentDir
			if parentDir == "" then paramParentDir = "/" else paramParentDir = parentDir  end  
			if not readOnly and not PSUploadAPI.createFolder (paramParentDir, newDir) then
				writeLogfile(1,"Create dir - parent: " .. paramParentDir .. " newDir: " .. newDir .. " failed!\n")
				return nil
			end
			dirsCreated[newPath] = true
		else
			writeLogfile(4,"  Directory: " .. newPath .. " already created\n")						
		end
	
		parentDir = newPath
		if slashPos == 0 then
			restDir = nil
		else
			restDir = string.sub(restDir, slashPos + 1)
		end
	end
	
	return dstDir
end

-----------------
-- uploadPicture(origFilename, srcFilename, srcPhoto, dstDir, dstFilename, isPS6, largeThumbs, thumbQuality) 
--[[
	generate all required thumbnails and upload thumbnails and the original picture as a batch.
	The upload batch must start with any of the thumbs and end with the original picture.
	When uploading to PhotoStation 6, we don't need to upload the THUMB_L
]]
function uploadPicture(origFilename, srcFilename, srcPhoto, dstDir, dstFilename, isPS6, largeThumbs, thumbQuality) 
	local picBasename = LrPathUtils.removeExtension(LrPathUtils.leafName(srcFilename))
--	local picBasename = LrPathUtils.removeExtension(LrPathUtils.leafName(origFilename))
	local picExt = LrPathUtils.extension(srcFilename)
	local thmb_XL_Filename = mkSaveFilename(LrPathUtils.child(tmpdir, LrPathUtils.addExtension(picBasename .. '_XL', picExt)))
	local thmb_L_Filename = iif(not isPS6, mkSaveFilename(LrPathUtils.child(tmpdir, LrPathUtils.addExtension(picBasename .. '_L', picExt))), '')
	local thmb_M_Filename = mkSaveFilename(LrPathUtils.child(tmpdir, LrPathUtils.addExtension(picBasename .. '_M', picExt)))
	local thmb_B_Filename = mkSaveFilename(LrPathUtils.child(tmpdir, LrPathUtils.addExtension(picBasename .. '_B', picExt)))
	local thmb_S_Filename = mkSaveFilename(LrPathUtils.child(tmpdir, LrPathUtils.addExtension(picBasename .. '_S', picExt)))
	local srcDateTime = getDateTimeOriginal(origFilename, srcPhoto)
	local retcode
	
	-- generate thumbs	
	if ( not largeThumbs and not PSConvert.convertPicConcurrent(srcFilename, 
								'-strip -flatten -quality '.. tostring(thumbQuality) .. ' -auto-orient -colorspace RGB -unsharp 0.5x0.5+1.25+0.0 -colorspace sRGB', 
								'1280x1280>', thmb_XL_Filename,
								'800x800>',    thmb_L_Filename,
								'640x640>',    thmb_B_Filename,
								'320x320>',    thmb_M_Filename,
								'120x120>',    thmb_S_Filename) )
	or ( largeThumbs and not PSConvert.convertPicConcurrent(srcFilename, 
								'-strip -flatten -quality '.. tostring(thumbQuality) .. ' -auto-orient -colorspace RGB -unsharp 0.5x0.5+1.25+0.0 -colorspace sRGB', 
								'1280x1280>^', thmb_XL_Filename,
								'800x800>^',   thmb_L_Filename,
								'640x640>^',   thmb_B_Filename,
								'320x320>^',   thmb_M_Filename,
								'120x120>^',   thmb_S_Filename) )

	-- upload thumbnails and original file
	or not PSUploadAPI.uploadPictureFile(thmb_B_Filename, srcDateTime, dstDir, dstFilename, 'THUM_B', 'image/jpeg', 'FIRST') 
	or not PSUploadAPI.uploadPictureFile(thmb_M_Filename, srcDateTime, dstDir, dstFilename, 'THUM_M', 'image/jpeg', 'MIDDLE') 
	or not PSUploadAPI.uploadPictureFile(thmb_S_Filename, srcDateTime, dstDir, dstFilename, 'THUM_S', 'image/jpeg', 'MIDDLE') 
	or (not isPS6 and not PSUploadAPI.uploadPictureFile(thmb_L_Filename, srcDateTime, dstDir, dstFilename, 'THUM_L', 'image/jpeg', 'MIDDLE'))
	or not PSUploadAPI.uploadPictureFile(thmb_XL_Filename, srcDateTime, dstDir, dstFilename, 'THUM_XL', 'image/jpeg', 'MIDDLE') 
	or not PSUploadAPI.uploadPictureFile(srcFilename, srcDateTime, dstDir, dstFilename, 'ORIG_FILE', 'image/jpeg', 'LAST') 
	then
		retcode = false
	else
		retcode = true
	end

	LrFileUtils.delete(thmb_B_Filename)
	LrFileUtils.delete(thmb_M_Filename)
	LrFileUtils.delete(thmb_S_Filename)
	if not isPS6 then LrFileUtils.delete(thmb_L_Filename) end
	LrFileUtils.delete(thmb_XL_Filename)

	return retcode
end

-----------------
-- uploadVideo(origVideoFilename, srcVideoFilename, srcPhoto, dstDir, dstFilename, isPS6, largeThumbs, thumbQuality, addVideo, hardRotate) 
--[[
	generate all required thumbnails, at least one video with alternative resolution (if we don't do, PhotoStation will do)
	and upload thumbnails, alternative video and the original video as a batch.
	The upload batch must start with any of the thumbs and end with the original video.
	When uploading to PhotoStation 6, we don't need to upload the THUMB_L
]]
function uploadVideo(origVideoFilename, srcVideoFilename, srcPhoto, dstDir, dstFilename, isPS6, largeThumbs, thumbQuality, addVideo, hardRotate) 
	local picBasename = LrPathUtils.removeExtension(LrPathUtils.leafName(srcVideoFilename))
	local vidExtOrg = LrPathUtils.extension(srcVideoFilename)
	local picPath = LrPathUtils.parent(srcVideoFilename)
	local picExt = 'jpg'
	local vidExt = 'mp4'
	local thmb_ORG_Filename = mkSaveFilename(LrPathUtils.child(picPath, LrPathUtils.addExtension(picBasename, picExt)))
	local thmb_XL_Filename = mkSaveFilename(LrPathUtils.child(picPath, LrPathUtils.addExtension(picBasename .. '_XL', picExt)))
	local thmb_L_Filename = iif(not isPS6, mkSaveFilename(LrPathUtils.child(tmpdir, LrPathUtils.addExtension(picBasename .. '_L', picExt))), '')
	local thmb_M_Filename = mkSaveFilename(LrPathUtils.child(picPath, LrPathUtils.addExtension(picBasename .. '_M', picExt)))
	local thmb_B_Filename = mkSaveFilename(LrPathUtils.child(picPath, LrPathUtils.addExtension(picBasename .. '_B', picExt)))
	local thmb_S_Filename = mkSaveFilename(LrPathUtils.child(picPath, LrPathUtils.addExtension(picBasename .. '_S', picExt)))
	local vid_MOB_Filename = mkSaveFilename(LrPathUtils.child(picPath, LrPathUtils.addExtension(picBasename .. '_MOB', vidExt))) 	--  240p
	local vid_LOW_Filename = mkSaveFilename(LrPathUtils.child(picPath, LrPathUtils.addExtension(picBasename .. '_LOW', vidExt)))	--  360p
	local vid_MED_Filename = mkSaveFilename(LrPathUtils.child(picPath, LrPathUtils.addExtension(picBasename .. '_MED', vidExt)))	--  720p
	local vid_HIGH_Filename = mkSaveFilename(LrPathUtils.child(picPath, LrPathUtils.addExtension(picBasename .. '_HIGH', vidExt)))	-- 1080p
	local realDimension
	local retcode
	local convKeyOrig, convKeyAdd, dummyIndex
	local vid_Orig_Filename, vid_Add_Filename
	
	writeLogfile(3, string.format("uploadVideo: %s\n", srcVideoFilename)) 

	local convParams = { 
		HIGH =  	{ height = 1080,	filename = vid_HIGH_Filename },
		MEDIUM = 	{ height = 720, 	filename = vid_MED_Filename },
		LOW =		{ height = 360, 	filename = vid_LOW_Filename },
		MOBILE =	{ height = 240,		filename = vid_MOB_Filename },
	}
	
	-- get video infos: DateTimeOrig, duration, dimension, sample aspect ratio, display aspect ratio
	local retcode, srcDateTime, duration, dimension, sampleAR, dispAR, rotation = PSConvert.ffmpegGetAdditionalInfo(srcVideoFilename)
	if not retcode then
		return false
	end
	
	-- look also for DateTimeOriginal in Metadata: if metadata include DateTimeOrig, then this will 
	-- overwrite the ffmpeg DateTimeOrig 
	local metaDateTime, isOrigDateTime = getDateTimeOriginal(origVideoFilename, srcPhoto)
	if isOrigDateTime or not srcDateTime then
		srcDateTime = metaDateTime
	end
	
	-- get the real dimension: may be different from dimension if dar is set
	-- dimension: NNNxMMM
	local srcHeight = tonumber(string.sub(dimension, string.find(dimension,'x') + 1, -1))
	if (ifnil(dispAR, '') == '') or (ifnil(sampleAR,'') == '1:1') then
		realDimension = dimension
		-- aspectRatio: NNN:MMM
		dispAR = string.gsub(dimension, 'x', ':')
	else
		local darWidth = tonumber(string.sub(dispAR, 1, string.find(dispAR,':') - 1))
		local darHeight = tonumber(string.sub(dispAR, string.find(dispAR,':') + 1, -1))
		local realSrcWidth = srcHeight * darWidth / darHeight
		realDimension = tostring(realSrcWidth) .. 'x' .. srcHeight
	end
	
	-- get the right conversion settings (depending on Height)
	dummyIndex, convKeyOrig = PSConvert.getConvertKey(srcHeight)
	vid_Replace_Filename = convParams[convKeyOrig].filename
	convKeyAdd = addVideo[convKeyOrig]
	if convKeyAdd ~= 'None' then
		vid_Add_Filename = convParams[convKeyAdd].filename
	end

	-- search for "Rotate-nn" in keywords, this will add/overwrite rotation infos from mpeg header
	local addRotate = false
	local keywords = srcPhoto:getRawMetadata("keywords")
	for i = 1, #keywords do
		if string.find(keywords[i]:getName(), 'Rotate-') then
			local metaRotation = string.sub (keywords[i]:getName(), 8)
			if metaRotation ~= rotation then
				rotation = metaRotation
				addRotate = true
				break
			end
			writeLogfile(3, string.format("Keyword[%d]= %s, rotation= %s\n", i, keywords[i]:getName(), rotation))
		end
	end

	-- video rotation only if requested by export param or by keyword (meta-rotation)
	local videoRotation = '0'
	if hardRotate or addRotate then
		videoRotation = rotation
	end
	
	-- replace original video if srcVideo is not already mp4 or if video is to be rotated
	local replaceOrgVideo 
	if (string.lower(vidExtOrg) ~= vidExt) or (videoRotation ~= '0') then
		replaceOrgVideo = true
		vid_Orig_Filename = vid_Replace_Filename
	else
		replaceOrgVideo = false
		vid_Orig_Filename = srcVideoFilename
	end
	
	-- generate first thumb from video, rotation has to be done regardless of the hardRotate setting
	if not PSConvert.ffmpegGetThumbFromVideo (srcVideoFilename, thmb_ORG_Filename, realDimension, rotation)

	
	-- generate all other thumb from first thumb
	or ( not largeThumbs and not PSConvert.convertPicConcurrent(thmb_ORG_Filename, 
								'-strip -flatten -quality '.. tostring(thumbQuality) .. ' -auto-orient -colorspace RGB -unsharp 0.5x0.5+1.25+0.0 -colorspace sRGB', 
								'1280x1280>', thmb_XL_Filename,
								'800x800>',    thmb_L_Filename,
								'640x640>',    thmb_B_Filename,
								'320x320>',    thmb_M_Filename,
								'120x120>',    thmb_S_Filename) )
	
	or ( largeThumbs and not PSConvert.convertPicConcurrent(thmb_ORG_Filename, 
								'-strip -flatten -quality '.. tostring(thumbQuality) .. ' -auto-orient -colorspace RGB -unsharp 0.5x0.5+1.25+0.0 -colorspace sRGB', 
								'1280x1280>^', thmb_XL_Filename,
								'800x800>^',   thmb_L_Filename,
								'640x640>^',   thmb_B_Filename,
								'320x320>^',   thmb_M_Filename,
								'120x120>^',   thmb_S_Filename) )

	-- generate mp4 in original size if srcVideo is not already mp4 or if video is rotated
	or (replaceOrgVideo and not PSConvert.convertVideo(srcVideoFilename, srcDateTime, dispAR, srcHeight, hardRotate, videoRotation, vid_Replace_Filename))
	
	-- generate additional video, if requested
	or ((convKeyAdd ~= 'None') and not PSConvert.convertVideo(srcVideoFilename, srcDateTime, dispAR, convParams[convKeyAdd].height, hardRotate, videoRotation, vid_Add_Filename))

	-- upload thumbs, preview videos and original file
	or not PSUploadAPI.uploadPictureFile(thmb_B_Filename, srcDateTime, dstDir, dstFilename, 'THUM_B', 'image/jpeg', 'FIRST') 
	or not PSUploadAPI.uploadPictureFile(thmb_M_Filename, srcDateTime, dstDir, dstFilename, 'THUM_M', 'image/jpeg', 'MIDDLE') 
	or not PSUploadAPI.uploadPictureFile(thmb_S_Filename, srcDateTime, dstDir, dstFilename, 'THUM_S', 'image/jpeg', 'MIDDLE') 
	or (not isPS6 and not PSUploadAPI.uploadPictureFile(thmb_L_Filename, srcDateTime, dstDir, dstFilename, 'THUM_L', 'image/jpeg', 'MIDDLE')) 
	or not PSUploadAPI.uploadPictureFile(thmb_XL_Filename, srcDateTime, dstDir, dstFilename, 'THUM_XL', 'image/jpeg', 'MIDDLE') 
	or ((convKeyAdd ~= 'None') and not PSUploadAPI.uploadPictureFile(vid_Add_Filename, srcDateTime, dstDir, dstFilename, 'MP4_'.. convKeyAdd, 'video/mpeg', 'MIDDLE'))
	or not PSUploadAPI.uploadPictureFile(vid_Orig_Filename, srcDateTime, dstDir, dstFilename, 'ORIG_FILE', 'video/mpeg', 'LAST') 
	then 
		retcode = false
	else 
		retcode = true
	end
	
	LrFileUtils.delete(thmb_ORG_Filename)
	LrFileUtils.delete(thmb_B_Filename)
	LrFileUtils.delete(thmb_M_Filename)
	LrFileUtils.delete(thmb_S_Filename)
	if not isPS6 then LrFileUtils.delete(thmb_L_Filename) end
	LrFileUtils.delete(thmb_XL_Filename)
	LrFileUtils.delete(vid_Orig_Filename)
	if vid_Add_Filename then LrFileUtils.delete(vid_Add_Filename) end

	return retcode
end

--------------------------------------------------------------------------------

-- checkMoved(publishedCollection, exportContext)
-- check all photos in a collection if locally moved
-- all moved photos get status "to be re-published"
-- return:
-- 		nPhotos		- # of photos in collection
--		nProcessed 	- # of photos checked
--		nMoved		- # of photos found to be moved
function checkMoved(publishedCollection, exportContext)
	local exportParams = exportContext.propertyTable
	local publishedPhotos = publishedCollection:getPublishedPhotos() 
	local nPhotos = #publishedPhotos
	local nProcessed = 0
	local nMoved = 0 

	-- Set progress title.
	local progressScope = exportContext:configureProgress {
						title = nPhotos > 1
							and LOC( "$$$/PSUpload/Upload/Progress=Checking ^1 photos for movement", nPhotos )
							or LOC "$$$/PSUpload/Upload/Progress/One=Checking one photo for movement",
						renderPortion = 1 / nPhotos,
					}
					
	for i = 1, nPhotos do
		if progressScope:isCanceled() then break end
		
		local pubPhoto = publishedPhotos[i]
		local srcPhoto = pubPhoto:getPhoto()
		local srcPhotoPath = srcPhoto:getRawMetadata('path')
		local publishedPath = ifnil(pubPhoto:getRemoteId(), '<Nil>')
		local edited = pubPhoto:getEditedFlag()
		
		local localPath, remotePath = getPublishPath(srcPhotoPath, srcPhoto, nil, exportParams)
		writeLogfile(3, "CheckMoved(" .. tostring(i) .. ", s= "  .. srcPhotoPath  .. ", r =" .. remotePath .. ", lastRemote= " .. publishedPath .. ", edited= " .. tostring(edited) .. ")\n")
		-- ignore extension: might be different 
		if LrPathUtils.removeExtension(remotePath) ~= LrPathUtils.removeExtension(publishedPath) then
			writeLogfile(2, "CheckMoved(" .. localPath .. " must be moved at target from " .. publishedPath .. 
							" to " .. remotePath .. ", edited= " .. tostring(edited) .. ")\n")
			catalog:withWriteAccessDo( 
				'SetEdited',
				function(context)
					pubPhoto:setEditedFlag(true)
				end,
				{timeout=5}
			)
			nMoved = nMoved + 1
		else
			writeLogfile(2, "CheckMoved(" .. localPath .. ") not moved.\n")
		end
		nProcessed = i
		progressScope:setPortionComplete(nProcessed, nPhotos)
	end 
	progressScope:done()
	
	return nPhotos, nProcessed, nMoved
end			

--------------------------------------------------------------------------------

-- PSUploadTask.updateExportSettings(exportSettings)
-- This plug-in defined callback function is called at the beginning
-- of each export and publish session before the rendition objects are generated.
function PSUploadTask.updateExportSettings(exportSettings)
-- do some initialization stuff
	local prefs = LrPrefs.prefsForPlugin()

	-- Start Debugging
	openLogfile(exportSettings.logLevel)
	
	-- check for updates once a day
	LrTasks.startAsyncTaskWithoutErrorHandler(PSUpdate.checkForUpdate, "PSUploadCheckForUpdate")

	writeLogfile(3, "updateExportSettings: done\n" )
end

--------------------------------------------------------------------------------

-- PSUploadTask.processRenderedPhotos( functionContext, exportContext )
-- The export callback called from Lr when the export starts
function PSUploadTask.processRenderedPhotos( functionContext, exportContext )
	-- Make a local reference to the export parameters.
	local exportSession = exportContext.exportSession
	local exportParams = exportContext.propertyTable

	local catalog = LrApplication.activeCatalog()
	local message
	local nPhotos
	local nProcessed = 0
	local nNotCopied = 0 	-- Publish / CheckExisting: num of pics not copied
	local nNeedCopy = 0 	-- Publish / CheckExisting: num of pics that need to be copied
	local timeUsed
	local timePerPic
	local readOnly = false
	local publishMode

	-- additionalVideo table: user selected additional video resolutions
	local additionalVideos = {
		HIGH = 		exportParams.addVideoHigh,
		MEDIUM = 	exportParams.addVideoMed,
		LOW = 		exportParams.addVideoLow,
		MOBILE = 	'None',
	}
	
	writeLogfile(2, "processRenderedPhotos starting\n" )
	
	-- check if this rendition process is an export or a publish
	local publishedCollection = exportContext.publishedCollection
	if publishedCollection then
		-- copy collectionSettings to exportParams
		copyCollectionSettingsToExportParams(publishedCollection:getCollectionInfoSummary().collectionSettings, exportParams)
		publishMode = exportParams.publishMode
	else
		publishMode = 'Export'
	end
		
	-- open session: initialize environment, get missing params and login
	if not openSession(exportParams, publishMode) then
		writeLogfile(1, "processRenderedPhotos: cannot open session!\n" )
		return
	end

	-- publishMode may have changed from 'Ask' to something different
	publishMode = exportParams.publishMode
	writeLogfile(2, "processRenderedPhotos(mode: " .. publishMode .. ").\n")

	local startTime = LrDate.currentTime()

	if publishMode == "CheckMoved" then
		-- Publish mode CheckMoved: makes no sense if not mirror tree mode
		local nMoved
		if not exportParams.copyTree then
			message = LOC ("$$$/PSUpload/Upload/Errors/CheckMovedNotNeeded=PhotoStation Upload (Check Moved): No mirror tree copy, no need to check for moved pics.\n")
		else
			nPhotos, nProcessed, nMoved = checkMoved(publishedCollection, exportContext)
			timeUsed = 	LrDate.currentTime() - startTime
			timePerPic = nProcessed / timeUsed 			-- pic per sec makes more sense her
			message = LOC ("$$$/PSUpload/Upload/Errors/CheckMoved=" .. 
							string.format("PhotoStation Upload (Check Moved): Checked %d of %d pics in %d seconds (%.1f pic/sec). Found %d moved pics.\n", 
							nProcessed, nPhotos, timeUsed + 0.5, timePerPic, nMoved))
		end
		showFinalMessage("PhotoStation CheckMoved done", message, "info")
		closeLogfile()
		closeSession(exportParams, publishMode)
		return
	end

	-- Set progress title.
	nPhotos = exportSession:countRenditions()

	local progressScope = exportContext:configureProgress {
						title = nPhotos > 1
							   and LOC( "$$$/PSUpload/Upload/Progress=Uploading ^1 photos to PhotoStation", nPhotos )
							   or LOC "$$$/PSUpload/Upload/Progress/One=Uploading one photo to PhotoStation",
					}

	writeLogfile(2, "--------------------------------------------------------------------\n")
	

	-- if is Publish process and publish mode is 'CheckExisting' ...
	if publishMode == 'CheckExisting' then
		-- remove all photos from rendering process to speed up the process
		readOnly = true
		for i, rendition in exportSession:renditions() do
			rendition:skipRender()
		end 
	end
	-- Iterate through photo renditions.
	local failures = {}
	local dirsCreated = {}
	
	for _, rendition in exportContext:renditions{ stopIfCanceled = true } do
		local publishedPhotoId = rendition.publishedPhotoId		-- only required for publishing
		local newPublishedPhotoId = nil
		-- Wait for next photo to render.

		local success, pathOrMessage = rendition:waitForRender()
		
		-- Check for cancellation again after photo has been rendered.
		
		if progressScope:isCanceled() then break end
		
		if success then
			writeLogfile(3, "\nNext photo: " .. pathOrMessage .. "\n")
			
			local srcPhoto = rendition.photo
			local renderedFilename = LrPathUtils.leafName( pathOrMessage )
			local srcFilename = srcPhoto:getRawMetadata("path") 
			local dstDir
		
			nProcessed = nProcessed + 1
			
			-- sanitize dstRoot: remove leading and trailings slashes
			if string.sub(exportParams.dstRoot,1,1) == "/" then exportParams.dstRoot = string.sub(exportParams.dstRoot, 2) end
			if string.sub(exportParams.dstRoot, string.len(exportParams.dstRoot)) == "/" then exportParams.dstRoot = string.sub(exportParams.dstRoot, 1, -2) end
			writeLogfile(4, "  sanitized dstRoot: " .. exportParams.dstRoot .. "\n")
			
			local localPath, newPublishedPhotoId
			
			if publishMode ~= 'Export' then
				-- publish process: generated a unique remote id for later modifications or deletions
				-- use the relative destination pathname, so we are able to identify moved pictures
				localPath, newPublishedPhotoId = getPublishPath(srcFilename, srcPhoto, renderedFilename, exportParams)
				
				writeLogfile(3, 'Old publishedPhotoId:' .. ifnil(publishedPhotoId, '<Nil>') .. ',  New publishedPhotoId:  ' .. newPublishedPhotoId .. '"\n')
				-- if photo was moved ... 
				if ifnil(publishedPhotoId, newPublishedPhotoId) ~= newPublishedPhotoId then
					-- remove photo at old location
					if publishMode == 'Publish' then 
						writeLogfile(2, 'Deleting remote photo at old path: ' .. publishedPhotoId .. '"\n')
						PSFileStationAPI.deletePic(publishedPhotoId) 
					end
				end
				publishedPhotoId = newPublishedPhotoId
				renderedFilename = LrPathUtils.leafName(publishedPhotoId)
			end
			
			if publishMode == 'CheckExisting' then
				-- check if photo already in PhotoStation
				local foundPhoto = PSFileStationAPI.existsPic(publishedPhotoId)
				if foundPhoto == 'yes' then
					rendition:recordPublishedPhotoId(publishedPhotoId)
					nNotCopied = nNotCopied + 1
					writeLogfile(2, 'Upload of "' .. LrPathUtils.leafName(localPath) .. '" to "' .. publishedPhotoId .. '" not needed, already there (mode: CheckExisting)\n')
				elseif foundPhoto == 'no' then
					-- do not acknowledge, so it will be left as "need copy"
					nNeedCopy = nNeedCopy + 1
					writeLogfile(2, 'Upload of "' .. LrPathUtils.leafName(localPath) .. '" to "' .. ifnil(LrPathUtils.parent(publishedPhotoId), "/") .. '" needed, but suppressed (mode: CheckExisting)!\n')
				else -- error
					table.insert( failures, srcFilename )
					break 
				end	
			elseif publishMode == 'Export' or publishMode == 'Publish' then
				-- normal publish or export process 
				-- check if target Album (dstRoot) should be created 
				if exportParams.createDstRoot and not createTree( './' .. exportParams.dstRoot,  ".", "", dirsCreated, readOnly) then
					table.insert( failures, srcFilename )
					break 
				end
			
				-- check if tree structure should be preserved
				if not exportParams.copyTree then
					-- just put it into the configured destination folder
					if not exportParams.dstRoot or exportParams.dstRoot == '' then
						dstDir = '/'
					else
						dstDir = exportParams.dstRoot
					end
				else
					dstDir = createTree( LrPathUtils.parent(srcFilename), exportParams.srcRoot, exportParams.dstRoot, dirsCreated, readOnly) 
				end
				
				if not dstDir then 	
					table.insert( failures, srcFilename )
					break 
				end

				if srcPhoto:getRawMetadata("isVideo") then
					writeLogfile(4, pathOrMessage .. ": is video\n") 
					if not uploadVideo(srcFilename, pathOrMessage, srcPhoto, dstDir, renderedFilename, exportParams.isPS6, exportParams.largeThumbs, exportParams.thumbQuality, 
										additionalVideos, exportParams.hardRotate) then
						writeLogfile(1, 'Upload of "' .. renderedFilename .. '" to "' .. dstDir .. '" failed!!!\n')
						table.insert( failures, dstDir .. "/" .. renderedFilename )
					else
						if publishedCollection then rendition:recordPublishedPhotoId(publishedPhotoId) end
						writeLogfile(2, 'Upload of "' .. renderedFilename .. '" to "' .. dstDir .. '" done\n')
					end
				else
					if not uploadPicture(srcFilename, pathOrMessage, srcPhoto, dstDir, renderedFilename, exportParams.isPS6, exportParams.largeThumbs, exportParams.thumbQuality) then
						writeLogfile(1, 'Upload of "' .. renderedFilename .. '" to "' .. exportParams.serverUrl .. "-->" ..  dstDir .. '" failed!!!\n')
						table.insert( failures, dstDir .. "/" .. renderedFilename )
					else
						if publishedCollection then rendition:recordPublishedPhotoId(publishedPhotoId) end
						writeLogfile(2, 'Upload of "' .. renderedFilename .. '" to "' .. exportParams.serverUrl .. "-->" .. dstDir .. '" done\n')
					end
				end
			end
			
			LrFileUtils.delete( pathOrMessage )
		end
	end

	writeLogfile(2,"--------------------------------------------------------------------\n")
	closeSession(exportParams, publishMode)
	
	timeUsed = 	LrDate.currentTime() - startTime
	timePerPic = timeUsed / nProcessed
	
	if #failures > 0 then
		message = LOC ("$$$/PSUpload/Upload/Errors/SomeFileFailed=" .. 
						string.format("PhotoStation Upload: Processed %d of %d pics in %d seconds (%.1f secs/pic). %d failed to upload.\n", 
						nProcessed, nPhotos, timeUsed, timePerPic, #failures))
		local action = LrDialogs.confirm(message, table.concat( failures, "\n" ), "Goto Logfile", "Never mind")
		if action == "ok" then
			LrShell.revealInShell(logfilename)
		end
	else
		if readOnly then
			message = LOC ("$$$/PSUpload/Upload/Errors/CheckExistOK=" .. 
							 string.format("PhotoStation Upload (Check Existing): Checked %d of %d files in %d seconds (%.1f secs/pic). %d already there, %d need export.", 
											nProcessed, nPhotos, timeUsed + 0.5, timePerPic, nNotCopied, nNeedCopy))
		else
			message = LOC ("$$$/PSUpload/Upload/Errors/UploadOK=" ..
							 string.format("PhotoStation Upload: Uploaded %d of %d files in %d seconds (%.1f secs/pic).", 
											nProcessed, nPhotos, timeUsed + 0.5, timePerPic))
		end
		showFinalMessage("PhotoStation Upload done", message, "info")
		closeLogfile()
	end
end
