/*
	Copyright (c) 2008, Adobe Systems Incorporated
	Copyright (c) 2011, Pimm Hogeling and Edo Rivai
	Copyright (c) 2011, Cameron Desrochers
	All rights reserved.

	Redistribution and use in source and binary forms, with or without 
	modification, are permitted provided that the following conditions are
	met:

	* Redistributions of source code must retain the above copyright notice, 
	this list of conditions and the following disclaimer.

	* Redistributions in binary form must reproduce the above copyright
	notice, this list of conditions and the following disclaimer in the 
	documentation and/or other materials provided with the distribution.

	* Neither the name of Adobe Systems Incorporated nor the names of its 
	contributors may be used to endorse or promote products derived from 
	this software without specific prior written permission.

	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
	IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
	THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
	PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR 
	CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
	EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
	PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
	PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
	LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
	NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
	SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

package;
import flash.display.Bitmap;
import flash.display.BitmapData;
import flash.display.Sprite;
import flash.display.Stage;
import flash.errors.Error;
import flash.events.Event;
import flash.events.EventDispatcher;
import flash.events.IEventDispatcher;
import flash.events.ProgressEvent;
import flash.geom.Rectangle;
import flash.Lib;
import flash.Memory;
import flash.system.ApplicationDomain;
import flash.system.System;
import flash.utils.ByteArray;
import flash.utils.Endian;
import flash.Vector;
import DeflateStream;


// Separate public interface from private implementation because all
// members appear as public in SWC
class PNGEncoder2 extends EventDispatcher
{
	// For internal use only. Do not access.
	private var __impl : PNGEncoder2Impl;
	
	public static var level : CompressionLevel;
	
	@:protected private inline function getPng() return __impl.png
	@:protected public var png(getPng, null) : ByteArray;
	@:getter(png) private function flGetPng() return getPng()
	
	
	/**
	 * Creates a PNG image from the specified BitmapData.
	 * Highly optimized for speed.
	 *
	 * @param image The BitmapData that will be converted into the PNG format.
	 * @return a ByteArray representing the PNG encoded image data.
	 * @playerversion Flash 10
	 */
	public static function encode(image : BitmapData) : ByteArray
	{
		PNGEncoder2Impl.level = level;
		return PNGEncoder2Impl.encode(image);
	}
	
	
	/**
	 * Creates a PNG image from the specified BitmapData without blocking.
	 * Highly optimized for speed.
	 *
	 * @param image The BitmapData that will be converted into the PNG format.
	 * @return a PNGEncoder2 object that dispatches COMPLETE and PROGRESS events.
	 * @playerversion Flash 10
	 */
	public static function encodeAsync(image : BitmapData) : PNGEncoder2
	{
		PNGEncoder2Impl.level = level;
		return new PNGEncoder2(image);
	}
	
	
	private inline function new(image : BitmapData)
	{
		super();
		
		__impl = new PNGEncoder2Impl(image, this);
	}
}


@:protected private class PNGEncoder2Impl
{
	private static inline var CRC_TABLE_END = 256 * 4;
	private static inline var DEFLATE_SCRATCH = CRC_TABLE_END;
	private static inline var CHUNK_START = DEFLATE_SCRATCH + DeflateStream.SCRATCH_MEMORY_SIZE;
	private static inline var FRAME_AVG_SMOOTH_COUNT = 4;	// Must be power of 2. Number of frames to calculate averages from
	private static inline var MIN_PIXELS_PER_FRAME = 16 * 1024;
	private static var data : ByteArray;
	private static var sprite : Sprite;		// Used to listen to ENTER_FRAME events
	private static var encoding = false;
	
	// FAST compression level is recommended (and default)
	public static var level : CompressionLevel;
	
	public var png : ByteArray;
	
	private var img : BitmapData;
	private var dispatcher : IEventDispatcher;
	private var deflateStream : DeflateStream;
	private var currentY : Int;
	private var msPerFrame : Vector<Int>;
	private var msPerFrameIndex : Int;
	private var msPerLine : Vector<Float>;
	private var msPerLineIndex : Int;
	private var lastFrameStart : Int;
	private var step : Int;
	private var targetMs : Float;
	private var done : Bool;
	
	private var frameCount : Int;
	
	public static inline function encode(img : BitmapData) : ByteArray
	{
		// Save current domain memory and restore it after, to avoid
		// conflicts with other components using domain memory
		var oldFastMem = ApplicationDomain.currentDomain.domainMemory;
		
		var png = beginEncoding(img);
		
		// Initialize stream for IDAT chunks
		var deflateStream = DeflateStream.createEx(level, DEFLATE_SCRATCH, CHUNK_START, true);
		
		writeIDATChunk(img, 0, img.height, deflateStream, png);
		
		endEncoding(png);
		
		Memory.select(oldFastMem);
		return png;
	}
	
	private static inline function beginEncoding(img : BitmapData) : ByteArray
	{
		if (encoding) {
			throw new Error("Only one PNG can be encoded at once");
		}
		
		encoding = true;
		
		
		if (level == null) {
			level = FAST;
		}
		
		// Data will be select()ed for use with fast memory
		// The first 256 * 4 bytes are the CRC table
		// Inner chunk data is appended to the CRC table, starting at CHUNK_START
		
		initialize();		// Sets up data var & CRC table
		
		// Create output byte array
		var png:ByteArray = new ByteArray();
		
		writePNGSignature(png);
		
		writeIHDRChunk(img, png);
		
		return png;
	}
	
	
	private static inline function endEncoding(png : ByteArray)
	{
		writeIENDChunk(png);
		
		encoding = false;
		
		png.position = 0;
	}
	
	
	
	public inline function new(image : BitmapData, dispatcher : IEventDispatcher)
	{
		_new(image, dispatcher);		// Constructors are slow -- delegate to function
	}
	
	private function _new(image : BitmapData, dispatcher : IEventDispatcher)
	{
		fastNew(image, dispatcher);
	}
	
	private inline function fastNew(image : BitmapData, dispatcher : IEventDispatcher)
	{
		lastFrameStart = Lib.getTimer();
		
		var oldFastMem = ApplicationDomain.currentDomain.domainMemory;
		
		img = image;
		png = beginEncoding(img);
		currentY = 0;
		frameCount = 0;
		done = false;
		this.dispatcher = dispatcher;
		msPerFrame = new Vector<Int>(FRAME_AVG_SMOOTH_COUNT, true);
		msPerFrameIndex = 0;
		msPerLine = new Vector<Float>(FRAME_AVG_SMOOTH_COUNT, true);
		msPerLineIndex = 0;
		
		deflateStream = DeflateStream.createEx(level, DEFLATE_SCRATCH, CHUNK_START, true);
		
		sprite.addEventListener(Event.ENTER_FRAME, onEnterFrame);
		
		if (img.width > 0 && img.height > 0) {
			// Determine proper step
			var startTime = Lib.getTimer();
			
			// Write first ~20K pixels to see how fast it is
			var height = Std.int(Math.min(20 * 1024 / img.width, img.height));
			writeIDATChunk(img, 0, height, deflateStream, png);
			
			var endTime = Lib.getTimer();
			updateMsPerLine(endTime - startTime, height);
			
			// Use unmeasured FPS as guestimate to seed msPerFrame
			var fps = Lib.current == null || Lib.current.stage == null ? 24 : Lib.current.stage.frameRate;
			updateMsPerFrame(Std.int(1.0 / fps * 1000));
			
			updateStep();
			
			currentY = height;
		}
		else {
			// A dimension is 0
			step = img.height;
		}
		
		Memory.select(oldFastMem);
	}
	
	
	private inline function updateMsPerLine(ms : Int, lines : Int)
	{
		if (lines != 0) {
			if (ms == 0) {
				// Can occasionally happen because timer resolution on Windows is limited to 10ms
				ms = 5;		// Guess!
			}
			
			msPerLine[msPerLineIndex] = ms * 1.0 / lines;
			msPerLineIndex = (msPerLineIndex + 1) & (FRAME_AVG_SMOOTH_COUNT - 1);	// Cheap modulus
		}
	}
	
	private inline function updateMsPerFrame(ms : Int)
	{
		msPerFrame[msPerFrameIndex] = ms;
		msPerFrameIndex = (msPerFrameIndex + 1) & (FRAME_AVG_SMOOTH_COUNT - 1);		// Cheap modulus
	}
	
	private inline function updateStep()
	{
		// Data: We have the last FRAME_AVG_SMOOTH_COUNT measurements
		// of time between frames.
		
		// Goal: Maximize the amount of processing we do each frame without
		// causing the frame rate to dip.
		// The time between frames should be stable, leading to deltas
		// near 0. If there are spare CPU cycles between frames, then
		// processing more data will not cause the frame rate to dip.
		// We constantly monitor the average change in time-per-frame
		// from the previous frame to the next. If the delta is positive
		// (i.e. the FPS is rising), that's good, and we take advantage
		// and do more processing (to ensure we're using all free CPU
		// cycles). If the delta is negative, it means we (or someone else)
		// is doing too much work per frame, and we should cut back on
		// the work we do per frame (and there's a minimum to ensure that
		// we at least get *some* work done each frame).
		
		
		// Calculate average delta
		
		// Set index to previous data point (one before current)
		var i = (msPerFrameIndex - 2 + FRAME_AVG_SMOOTH_COUNT) & (FRAME_AVG_SMOOTH_COUNT - 1);
		if (msPerFrame[i] <= 0) {
			// No delta since there's only one data point so far
			
			targetMs = msPerFrame[0] * 1.5;	// Probably too much, but better more than less (it will be corrected later)
		}
		else {
			var avgDelta = 0.0;
			var count = 0;
			
			var end = (i + 1) & (FRAME_AVG_SMOOTH_COUNT - 1);
			while (i != end) {
				if (msPerFrame[i] >= 0) {
					avgDelta += msPerFrame[i] - msPerFrame[(i + i) & (FRAME_AVG_SMOOTH_COUNT - 1)];
					++count;
				}
				
				i = (i - 1 + FRAME_AVG_SMOOTH_COUNT) & (FRAME_AVG_SMOOTH_COUNT - 1);
			}
			
			avgDelta /= count;
			if (avgDelta >= 0) {
				// Frame-rate increasing
				// Push until framerate is decreasing to ensure all free CPU cycles are taken
				targetMs = Math.max(targetMs * 1.08, targetMs + avgDelta * 0.75);
			}
			else {
				// Frame-rate decreasing, take corrective action
				targetMs += avgDelta * 0.5;		// Note avgDelta is negative here
			}
		}
		
		
		var avgMsPerLine = 0.0;
		var count = 0;
		for (ms in msPerLine) {
			if (ms > 0) {
				avgMsPerLine += ms;
				++count;
			}
		}
		if (count != 0) {
			avgMsPerLine /= count;
			step = Math.ceil(Math.max(targetMs / avgMsPerLine, MIN_PIXELS_PER_FRAME / img.width));
		}
		else {
			step = Math.ceil(MIN_PIXELS_PER_FRAME / img.width);
		}
	}
	
	
	private function onEnterFrame(e : Event)
	{
		_onEnterFrame();
	}
	
	private inline function _onEnterFrame()
	{
		var _end : Int;
		
		if (!done) {
			++frameCount;
			
			var oldFastMem = ApplicationDomain.currentDomain.domainMemory;
			Memory.select(data);
			
			var start = Lib.getTimer();
			updateMsPerFrame(start - lastFrameStart);
			lastFrameStart = start;
			
			// Queue events instead of dispatching them inline
			// because during a call to dispatchEvent *other* pending events
			// might be dispatched too, possibly resulting in this method being
			// called again in a re-entrant fashion (which doesn't play nicely
			// with storing/retrieving oldFastMem).
			var queuedEvents = new Vector<Event>();
			
			var bytesPerPixel = img.transparent ? 4 : 3;
			var totalBytes = bytesPerPixel * img.width * img.height;
			
			if (currentY >= img.height) {
				// Finished encoding the entire image in the initial setup
				queuedEvents.push(new ProgressEvent(ProgressEvent.PROGRESS, false, false, totalBytes, totalBytes));
				finalize(queuedEvents);
			}
			else {
				var next = Std.int(Math.min(currentY + step, img.height));
				writeIDATChunk(img, currentY, next, deflateStream, png);
				currentY = next;
				
				var currentBytes = bytesPerPixel * img.width * currentY;
				
				queuedEvents.push(new ProgressEvent(ProgressEvent.PROGRESS, false, false, currentBytes, totalBytes));
				
				finalize(queuedEvents);
				
				updateMsPerLine(Lib.getTimer() - start, step);
				updateStep();
			}
			
			Memory.select(oldFastMem);
			
			
			
			for (event in queuedEvents) {
				dispatcher.dispatchEvent(event);
			}
		}
	}
	
	
	private inline function finalize(queuedEvents : Vector<Event>)
	{
		if (currentY >= img.height) {
			done = true;
			
			sprite.removeEventListener(Event.ENTER_FRAME, onEnterFrame);
			
			endEncoding(png);
			
			queuedEvents.push(new Event(Event.COMPLETE));
			
			trace("Frames: " + frameCount);
		}
	}
	
	

	private static inline function writePNGSignature(png : ByteArray)
	{
		png.writeUnsignedInt(0x89504e47);
		png.writeUnsignedInt(0x0D0A1A0A);
	}
	
	
	private static inline function writeIHDRChunk(img : BitmapData, png : ByteArray)
	{
		var chunkLength = 13;
		data.length = Std.int(Math.max(CHUNK_START + chunkLength, ApplicationDomain.MIN_DOMAIN_MEMORY_LENGTH));
		Memory.select(data);
		
		writeI32BE(CHUNK_START, img.width);
		writeI32BE(CHUNK_START + 4, img.height);
		
		Memory.setByte(CHUNK_START + 8, 8);		// Bit depth
		
		if (img.transparent) {
			Memory.setByte(CHUNK_START + 9, 6);		// RGBA colour type
		}
		else {
			Memory.setByte(CHUNK_START + 9, 2);		// RGB colour type
		}
		
		Memory.setByte(CHUNK_START + 10, 0);	// Compression method (always 0 -> zlib)
		Memory.setByte(CHUNK_START + 11, 0);	// Filter method (always 0)
		Memory.setByte(CHUNK_START + 12, 0);	// No interlacing
		
		writeChunk(png, 0x49484452, chunkLength);
	}
	
	
	// Copies length bytes (all by default) from src into flash.Memory at the specified offset
	private static inline function memcpy(src : ByteArray, offset : UInt, length : UInt = 0) : Void
	{
		src.readBytes(ApplicationDomain.currentDomain.domainMemory, offset, length);
	}
	
	// Writes one integer into flash.Memory at the given address, in big-endian order
	private static inline function writeI32BE(addr: UInt, value : UInt) : Void
	{
		Memory.setByte(addr, value >>> 24);
		Memory.setByte(addr + 1, value >>> 16);
		Memory.setByte(addr + 2, value >>> 8);
		Memory.setByte(addr + 3, value);
	}
	
	
	private static function writeIDATChunk(img : BitmapData, startY : Int, endY : Int, deflateStream: DeflateStream, png : ByteArray)
	{
		_writeIDATChunk(img, startY, endY, deflateStream, png);
	}
	
	private static inline function _writeIDATChunk(img : BitmapData, startY : Int, endY : Int, deflateStream: DeflateStream, png : ByteArray)
	{
		var width = img.width;
		var height = endY - startY;
		var region = new Rectangle(0, startY, width, height);
		
		var bytesPerPixel = img.transparent ? 4 : 3;
		
		// Length of IDAT data: 3 or 4 bytes per pixel + 1 byte per scanline
		var length : UInt = width * height * bytesPerPixel + height;
		
		// Size needed to store byte array of bitmap
		var scratchSize : UInt = width * height * 4;
		
		// Memory layout:
		// DEFLATE_SCRATCH: Deflate stream scratch memory
		// CHUNK_START: Deflated data (written last)
		// CHUNK_START + deflated data buffer: scratch (raw image bytes)
		// CHUNK_START + deflated data buffer + scratchSize: Uncompressed PNG-format image data
		
		data.length = Std.int(Math.max(CHUNK_START + deflateStream.maxOutputBufferSize(length) + scratchSize + length, ApplicationDomain.MIN_DOMAIN_MEMORY_LENGTH));
		Memory.select(data);
		
		var scratchAddr : Int = CHUNK_START + deflateStream.maxOutputBufferSize(length);
		var addrStart : Int = scratchAddr + scratchSize;
		
		var addr = addrStart;
		var end8 = (width & 0xFFFFFFF4) - 8;		// Floor to nearest 8, then subtract 8
		var j;
		
		//var startTime = Lib.getTimer();
		
		var imgBytes = img.getPixels(region);
		imgBytes.position = 0;
		memcpy(imgBytes, scratchAddr);
		
		//var endTime = Lib.getTimer();
		//trace("Blitting pixel data into fast mem took " + (endTime - startTime) + "ms");
		
		//startTime = Lib.getTimer();
		if (img.transparent) {
			for (i in 0 ... height) {
				Memory.setByte(addr, 1);		// Sub filter
				addr += 1;
				
				if (width > 0) {
					// Do first pixel (4 bytes) manually (sub formula is different)
					Memory.setI32(addr, Memory.getI32(scratchAddr) >>> 8);
					Memory.setByte(addr + 3, Memory.getByte(scratchAddr + 0));
					addr += 4;
					scratchAddr += 4;
				
					// Copy line, moving alpha byte to end, and applying filter
					j = 1;
					while (j < end8) {
						Memory.setByte(addr + 0, Memory.getByte(scratchAddr + 1) - Memory.getByte(scratchAddr - 3));
						Memory.setByte(addr + 1, Memory.getByte(scratchAddr + 2) - Memory.getByte(scratchAddr - 2));
						Memory.setByte(addr + 2, Memory.getByte(scratchAddr + 3) - Memory.getByte(scratchAddr - 1));
						Memory.setByte(addr + 3, Memory.getByte(scratchAddr + 0) - Memory.getByte(scratchAddr - 4));
						
						Memory.setByte(addr + 4, Memory.getByte(scratchAddr + 5) - Memory.getByte(scratchAddr + 1));
						Memory.setByte(addr + 5, Memory.getByte(scratchAddr + 6) - Memory.getByte(scratchAddr + 2));
						Memory.setByte(addr + 6, Memory.getByte(scratchAddr + 7) - Memory.getByte(scratchAddr + 3));
						Memory.setByte(addr + 7, Memory.getByte(scratchAddr + 4) - Memory.getByte(scratchAddr + 0));
						
						Memory.setByte(addr +  8, Memory.getByte(scratchAddr +  9) - Memory.getByte(scratchAddr + 5));
						Memory.setByte(addr +  9, Memory.getByte(scratchAddr + 10) - Memory.getByte(scratchAddr + 6));
						Memory.setByte(addr + 10, Memory.getByte(scratchAddr + 11) - Memory.getByte(scratchAddr + 7));
						Memory.setByte(addr + 11, Memory.getByte(scratchAddr +  8) - Memory.getByte(scratchAddr + 4));
						
						Memory.setByte(addr + 12, Memory.getByte(scratchAddr + 13) - Memory.getByte(scratchAddr +  9));
						Memory.setByte(addr + 13, Memory.getByte(scratchAddr + 14) - Memory.getByte(scratchAddr + 10));
						Memory.setByte(addr + 14, Memory.getByte(scratchAddr + 15) - Memory.getByte(scratchAddr + 11));
						Memory.setByte(addr + 15, Memory.getByte(scratchAddr + 12) - Memory.getByte(scratchAddr +  8));
						
						Memory.setByte(addr + 16, Memory.getByte(scratchAddr + 17) - Memory.getByte(scratchAddr + 13));
						Memory.setByte(addr + 17, Memory.getByte(scratchAddr + 18) - Memory.getByte(scratchAddr + 14));
						Memory.setByte(addr + 18, Memory.getByte(scratchAddr + 19) - Memory.getByte(scratchAddr + 15));
						Memory.setByte(addr + 19, Memory.getByte(scratchAddr + 16) - Memory.getByte(scratchAddr + 12));
						
						Memory.setByte(addr + 20, Memory.getByte(scratchAddr + 21) - Memory.getByte(scratchAddr + 17));
						Memory.setByte(addr + 21, Memory.getByte(scratchAddr + 22) - Memory.getByte(scratchAddr + 18));
						Memory.setByte(addr + 22, Memory.getByte(scratchAddr + 23) - Memory.getByte(scratchAddr + 19));
						Memory.setByte(addr + 23, Memory.getByte(scratchAddr + 20) - Memory.getByte(scratchAddr + 16));
						
						Memory.setByte(addr + 24, Memory.getByte(scratchAddr + 25) - Memory.getByte(scratchAddr + 21));
						Memory.setByte(addr + 25, Memory.getByte(scratchAddr + 26) - Memory.getByte(scratchAddr + 22));
						Memory.setByte(addr + 26, Memory.getByte(scratchAddr + 27) - Memory.getByte(scratchAddr + 23));
						Memory.setByte(addr + 27, Memory.getByte(scratchAddr + 24) - Memory.getByte(scratchAddr + 20));
						
						Memory.setByte(addr + 28, Memory.getByte(scratchAddr + 29) - Memory.getByte(scratchAddr + 25));
						Memory.setByte(addr + 29, Memory.getByte(scratchAddr + 30) - Memory.getByte(scratchAddr + 26));
						Memory.setByte(addr + 30, Memory.getByte(scratchAddr + 31) - Memory.getByte(scratchAddr + 27));
						Memory.setByte(addr + 31, Memory.getByte(scratchAddr + 28) - Memory.getByte(scratchAddr + 24));
						
						
						addr += 32;
						scratchAddr += 32;
						j += 8;
					}
					while (j < width) {
						Memory.setByte(addr + 0, Memory.getByte(scratchAddr + 1) - Memory.getByte(scratchAddr - 3));
						Memory.setByte(addr + 1, Memory.getByte(scratchAddr + 2) - Memory.getByte(scratchAddr - 2));
						Memory.setByte(addr + 2, Memory.getByte(scratchAddr + 3) - Memory.getByte(scratchAddr - 1));
						Memory.setByte(addr + 3, Memory.getByte(scratchAddr + 0) - Memory.getByte(scratchAddr - 4));
						addr += 4;
						scratchAddr += 4;
						++j;
					}
				}
			}
		}
		else {
			for (i in 0 ... height) {
				Memory.setByte(addr, 1);		// Sub filter
				addr += 1;
				
				if (width > 0) {
					// Do first pixel (3 bytes) manually (sub formula is different)
					Memory.setByte(addr + 0, Memory.getByte(scratchAddr + 1));
					Memory.setByte(addr + 1, Memory.getByte(scratchAddr + 2));
					Memory.setByte(addr + 2, Memory.getByte(scratchAddr + 3));
					addr += 3;
					scratchAddr += 4;
					
					// Copy line
					j = 1;
					while (j < end8) {
						Memory.setByte(addr + 0, Memory.getByte(scratchAddr + 1) - Memory.getByte(scratchAddr - 3));
						Memory.setByte(addr + 1, Memory.getByte(scratchAddr + 2) - Memory.getByte(scratchAddr - 2));
						Memory.setByte(addr + 2, Memory.getByte(scratchAddr + 3) - Memory.getByte(scratchAddr - 1));
						
						Memory.setByte(addr + 3, Memory.getByte(scratchAddr + 5) - Memory.getByte(scratchAddr + 1));
						Memory.setByte(addr + 4, Memory.getByte(scratchAddr + 6) - Memory.getByte(scratchAddr + 2));
						Memory.setByte(addr + 5, Memory.getByte(scratchAddr + 7) - Memory.getByte(scratchAddr + 3));
						
						Memory.setByte(addr + 6, Memory.getByte(scratchAddr +  9) - Memory.getByte(scratchAddr + 5));
						Memory.setByte(addr + 7, Memory.getByte(scratchAddr + 10) - Memory.getByte(scratchAddr + 6));
						Memory.setByte(addr + 8, Memory.getByte(scratchAddr + 11) - Memory.getByte(scratchAddr + 7));
						
						Memory.setByte(addr +  9, Memory.getByte(scratchAddr + 13) - Memory.getByte(scratchAddr +  9));
						Memory.setByte(addr + 10, Memory.getByte(scratchAddr + 14) - Memory.getByte(scratchAddr + 10));
						Memory.setByte(addr + 11, Memory.getByte(scratchAddr + 15) - Memory.getByte(scratchAddr + 11));
						
						Memory.setByte(addr + 12, Memory.getByte(scratchAddr + 17) - Memory.getByte(scratchAddr + 13));
						Memory.setByte(addr + 13, Memory.getByte(scratchAddr + 18) - Memory.getByte(scratchAddr + 14));
						Memory.setByte(addr + 14, Memory.getByte(scratchAddr + 19) - Memory.getByte(scratchAddr + 15));
						
						Memory.setByte(addr + 15, Memory.getByte(scratchAddr + 21) - Memory.getByte(scratchAddr + 17));
						Memory.setByte(addr + 16, Memory.getByte(scratchAddr + 22) - Memory.getByte(scratchAddr + 18));
						Memory.setByte(addr + 17, Memory.getByte(scratchAddr + 23) - Memory.getByte(scratchAddr + 19));
						
						Memory.setByte(addr + 18, Memory.getByte(scratchAddr + 25) - Memory.getByte(scratchAddr + 21));
						Memory.setByte(addr + 19, Memory.getByte(scratchAddr + 26) - Memory.getByte(scratchAddr + 22));
						Memory.setByte(addr + 20, Memory.getByte(scratchAddr + 27) - Memory.getByte(scratchAddr + 23));
						
						Memory.setByte(addr + 21, Memory.getByte(scratchAddr + 29) - Memory.getByte(scratchAddr + 25));
						Memory.setByte(addr + 22, Memory.getByte(scratchAddr + 30) - Memory.getByte(scratchAddr + 26));
						Memory.setByte(addr + 33, Memory.getByte(scratchAddr + 31) - Memory.getByte(scratchAddr + 27));
						
						addr += 24;
						scratchAddr += 32;
						j += 8;
					}
					while (j < width) {
						Memory.setByte(addr + 0, Memory.getByte(scratchAddr + 1) - Memory.getByte(scratchAddr - 3));
						Memory.setByte(addr + 1, Memory.getByte(scratchAddr + 2) - Memory.getByte(scratchAddr - 2));
						Memory.setByte(addr + 2, Memory.getByte(scratchAddr + 3) - Memory.getByte(scratchAddr - 1));
						addr += 3;
						scratchAddr += 4;
						++j;
					}
				}
			}
		}
		
		//endTime = Lib.getTimer();
		//trace("Copying pixel data into RGBA format with filter took " + (endTime - startTime) + "ms");
		
		//var startTime = Lib.getTimer();
		
		deflateStream.fastWrite(addrStart, addrStart + length);
		
		var lastChunk = endY == img.height;
		var range = lastChunk ? deflateStream.fastFinalize() : deflateStream.peek();
		writeChunk(png, 0x49444154, range.len());
		
		if (!lastChunk) {
			deflateStream.release();
		}
		
		//var endTime = Lib.getTimer();
		//trace("Compression took " + (endTime - startTime) + "ms");
	}
	
	
	private static inline function writeIENDChunk(png : ByteArray)
	{
		writeChunk(png, 0x49454E44, 0);
	}
	

	private static inline function writeChunk(png : ByteArray, type : Int, chunkLength : Int) : Void
	{
		var len = chunkLength;
		
		png.writeUnsignedInt(len);
		png.writeUnsignedInt(type);
		if (len != 0) {
			data.position = CHUNK_START;
			data.readBytes(png, png.position, chunkLength);
			png.position += len;
		}
		
		var c : UInt = 0xFFFFFFFF;
		
		// Unroll first four iterations from type bytes, rest use chunk data
		c = crcTable(c ^ (type >>> 24)) ^ (c >>> 8);
		c = crcTable(c ^ ((type >>> 16) & 0xFF)) ^ (c >>> 8);
		c = crcTable(c ^ ((type >>> 8) & 0xFF)) ^ (c >>> 8);
		c = crcTable(c ^ (type & 0xFF)) ^ (c >>> 8);
		
		if (len != 0) {
			var i = CHUNK_START;
			var end = CHUNK_START + len;
			var end16 = CHUNK_START + (len & 0xFFFFFFF0);	// Floor to nearest 16
			while (i < end16) {
				c = crcTable(c ^ Memory.getByte(i)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 1)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 2)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 3)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 4)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 5)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 6)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 7)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 8)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 9)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 10)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 11)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 12)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 13)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 14)) ^ (c >>> 8);
				c = crcTable(c ^ Memory.getByte(i + 15)) ^ (c >>> 8);
				i += 16;
			}
			while (i < end) {
				c = crcTable(c ^ Memory.getByte(i)) ^ (c >>> 8);
				++i;
			}
		}
		c ^= 0xFFFFFFFF;
		
		png.writeUnsignedInt(c);
	}
	
	
	
	private static var crcComputed = false;
	
	private static inline function initialize() : Void
	{
		sprite = new Sprite();
		
		if (!crcComputed) {
			data = new ByteArray();
			data.length = Std.int(Math.max(CHUNK_START, ApplicationDomain.MIN_DOMAIN_MEMORY_LENGTH));
		}
		
		Memory.select(data);
		
		if (!crcComputed) {
			var c : UInt;
			for (n in 0 ... 256) {
				c = n;
				
				// 8 iterations
				if (c & 1 == 1) c = 0xedb88320 ^ (c >>> 1);
				else c >>>= 1;
				if (c & 1 == 1) c = 0xedb88320 ^ (c >>> 1);
				else c >>>= 1;
				if (c & 1 == 1) c = 0xedb88320 ^ (c >>> 1);
				else c >>>= 1;
				if (c & 1 == 1) c = 0xedb88320 ^ (c >>> 1);
				else c >>>= 1;
				if (c & 1 == 1) c = 0xedb88320 ^ (c >>> 1);
				else c >>>= 1;
				if (c & 1 == 1) c = 0xedb88320 ^ (c >>> 1);
				else c >>>= 1;
				if (c & 1 == 1) c = 0xedb88320 ^ (c >>> 1);
				else c >>>= 1;
				if (c & 1 == 1) c = 0xedb88320 ^ (c >>> 1);
				else c >>>= 1;
				
				Memory.setI32(n << 2, c);
			}
			
			crcComputed = true;
		}
	}
	
	private static inline function crcTable(index : UInt) : UInt
	{
		return Memory.getI32((index & 0xFF) << 2);
	}
}
