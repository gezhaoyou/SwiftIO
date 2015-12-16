//
//  CFSocketClientTransport.swift
//  swiftli
//
//  Created by Sriram Panyam on 12/14/15.
//  Copyright © 2015 Sriram Panyam. All rights reserved.
//

import Foundation


let DEFAULT_BUFFER_SIZE = 8192
public class CFSocketClientTransport : ClientTransport {
    var connection : Connection?
    var clientSocketNative : CFSocketNativeHandle
//    var clientSocket : CFSocket?
    var readStream : CFReadStream?
    var writeStream : CFWriteStream?
    var transportRunLoop : CFRunLoop?
    var writesAreEdgeTriggered = true
    
    init(_ clientSock : CFSocketNativeHandle, runLoop: CFRunLoop?) {
        clientSocketNative = clientSock;
        transportRunLoop = runLoop
        initStreams();
        setWriteable()
    }
    
    /**
     * Called to initiate consuming of the write buffers to send data down the connection.
     */
    public func setWriteable() {
        let writeEvents = CFStreamEventType.CanAcceptBytes.rawValue | CFStreamEventType.ErrorOccurred.rawValue | CFStreamEventType.EndEncountered.rawValue
        self.registerWriteEvents(writeEvents)
        
        // Should this be called here?
        // It is possible that a client can call this as many as 
        // time as it needs greedily
        if writesAreEdgeTriggered {
            CFRunLoopPerformBlock(transportRunLoop, kCFRunLoopCommonModes) { () -> Void in
                self.canAcceptBytes()
            }
        }
    }
    
    private func clearWriteable() {
        let writeEvents = CFStreamEventType.ErrorOccurred.rawValue | CFStreamEventType.EndEncountered.rawValue
        self.registerWriteEvents(writeEvents)
    }
    
    private func initStreams()
    {
        withUnsafeMutablePointer(&readStream) {
            let readStreamPtr = UnsafeMutablePointer<Unmanaged<CFReadStream>?>($0)
            withUnsafeMutablePointer(&writeStream, {
                let writeStreamPtr = UnsafeMutablePointer<Unmanaged<CFWriteStream>?>($0)
                CFStreamCreatePairWithSocket(kCFAllocatorDefault, clientSocketNative, readStreamPtr, writeStreamPtr)
            })
        }
        
        if readStream != nil && writeStream != nil {
            CFReadStreamSetProperty(readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
            CFWriteStreamSetProperty(writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
            
            // register with run loop
            var streamClientContext = CFStreamClientContext(version:0, info: self.asUnsafeMutableVoid(), retain: nil, release: nil, copyDescription: nil)
            let readEvents = CFStreamEventType.HasBytesAvailable.rawValue | CFStreamEventType.ErrorOccurred.rawValue | CFStreamEventType.EndEncountered.rawValue
            withUnsafePointer(&streamClientContext) {
                if (CFReadStreamSetClient(readStream, readEvents, readCallback, UnsafeMutablePointer<CFStreamClientContext>($0)))
                {
                    CFReadStreamScheduleWithRunLoop(readStream, transportRunLoop, kCFRunLoopCommonModes);
                }
            }
            
            if CFReadStreamOpen(readStream) && CFWriteStreamOpen(writeStream) {
                //use the streams
                print("Streams initialized")
            }
            else {
                print("Could not initialize streams!");
            }
        }
        
        // set its read/write/close events on the runloop
    }

    private func asUnsafeMutableVoid() -> UnsafeMutablePointer<Void>
    {
        let selfAsOpaque = Unmanaged<CFSocketClientTransport>.passUnretained(self).toOpaque()
        let selfAsVoidPtr = UnsafeMutablePointer<Void>(selfAsOpaque)
        return selfAsVoidPtr
    }

    func start(delegate : Connection) {
        connection = delegate
    }
    
    private func registerWriteEvents(events: CFOptionFlags) {
        if writeStream != nil {
            var streamClientContext = CFStreamClientContext(version:0, info: self.asUnsafeMutableVoid(), retain: nil, release: nil, copyDescription: nil)
            withUnsafePointer(&streamClientContext) {
                if (CFWriteStreamSetClient(writeStream, events, writeCallback, UnsafeMutablePointer<CFStreamClientContext>($0)))
                {
                    CFWriteStreamScheduleWithRunLoop(writeStream, transportRunLoop, kCFRunLoopCommonModes);
                }
            }
        }
    }
    
    var readBuffer = UnsafeMutablePointer<UInt8>.alloc(DEFAULT_BUFFER_SIZE)
    
    func connectionClosed() {
        connection?.connectionClosed()
    }
    
    func hasBytesAvailable() {
        // It is safe to call CFReadStreamRead; it won’t block because bytes are available.
        let bytesRead = CFReadStreamRead(readStream, readBuffer, DEFAULT_BUFFER_SIZE);
        if bytesRead > 0 {
            connection?.dataReceived(readBuffer, length: bytesRead)
        } else if bytesRead < 0 {
            handleReadError()
        }
    }
    
    func canAcceptBytes() {
        if let (buffer, length) = connection?.writeDataRequested() {
            if length > 0 {
                let numWritten = CFWriteStreamWrite(writeStream, buffer, length)
                if numWritten > 0 {
                    connection?.dataWritten(numWritten)
                } else if numWritten < 0 {
                    // error?
                    handleWriteError()
                }
                
                if numWritten >= 0 && numWritten < length {
                    // only partial data written so dont clear writeable.
                    // if this is the case then for an edge triggered API
                    // we have to ensure that canAcceptBytes will eventually 
                    // get called - this can happen by either connection calling
                    // setWriteable - this is not good as they can greedily keep 
                    // calling it OR we have to dispatch a canAcceptBytes in another 
                    // cycle of the runloop.
                    return
                }
            }
        }
        
        // no more bytes so clear writeable
        clearWriteable()
    }
    
    func handleReadError() {
        let error = CFReadStreamGetError(readStream);
        print("Read error: \(error)")
        CFReadStreamUnscheduleFromRunLoop(readStream, transportRunLoop, kCFRunLoopCommonModes);
    }
    
    func handleWriteError() {
        let error = CFWriteStreamGetError(writeStream);
        print("Write error: \(error)")
        CFWriteStreamUnscheduleFromRunLoop(writeStream, transportRunLoop, kCFRunLoopCommonModes);
    }
}

func readCallback(readStream: CFReadStream!, eventType: CFStreamEventType, info: UnsafeMutablePointer<Void>) -> Void
{
    let socketConnection = Unmanaged<CFSocketClientTransport>.fromOpaque(COpaquePointer(info)).takeUnretainedValue()
    if eventType == CFStreamEventType.HasBytesAvailable {
        socketConnection.hasBytesAvailable()
    } else if eventType == CFStreamEventType.EndEncountered {
        socketConnection.connectionClosed()
    } else if eventType == CFStreamEventType.ErrorOccurred {
        socketConnection.handleReadError()
    }
}

func writeCallback(writeStream: CFWriteStream!, eventType: CFStreamEventType, info: UnsafeMutablePointer<Void>) -> Void
{
    let socketConnection = Unmanaged<CFSocketClientTransport>.fromOpaque(COpaquePointer(info)).takeUnretainedValue()
    if eventType == CFStreamEventType.CanAcceptBytes {
        socketConnection.canAcceptBytes();
    } else if eventType == CFStreamEventType.EndEncountered {
        socketConnection.connectionClosed()
    } else if eventType == CFStreamEventType.ErrorOccurred {
        socketConnection.handleWriteError()
    }
}

//
//
//private func clientSocketCallback(socket: CFSocket!,
//    callbackType: CFSocketCallBackType,
//    address: CFData!,
//    data: UnsafePointer<Void>,
//    info: UnsafeMutablePointer<Void>)
//{
//    if callbackType == CFSocketCallBackType.ReadCallBack
//    {
//        print("Read callback")
////        let clientTransport = Unmanaged<CFSocketClientTransport>.fromOpaque(COpaquePointer(info)).takeUnretainedValue()
////        clientTransport.hasBytesAvailable()
//    } else if callbackType == CFSocketCallBackType.WriteCallBack
//    {
//        print("Write callback")
//        let clientTransport = Unmanaged<CFSocketClientTransport>.fromOpaque(COpaquePointer(info)).takeUnretainedValue()
//        clientTransport.canAcceptBytes()
//    }
//    //    if (callbackType == CFSocketCallBackType.ReadCallBack)
//    //    {
//    //        let socketTransport = Unmanaged<CFSocketServerTransport>.fromOpaque(COpaquePointer(info)).takeUnretainedValue()
//    //        let clientSocket = UnsafePointer<CFSocketNativeHandle>(data)
//    //        let clientSocketNativeHandle = clientSocket[0]
//    //        let socketConnection = CFSocketClientTransport(clientSocketNativeHandle)
//    //        var connection = socketTransport.connectionFactory?.connectionAccepted()
//    //        if connection != nil
//    //        {
//    //            connection?.transport = socketConnection
//    //            socketConnection.start(connection!)
//    //        } else {
//    //            // TODO: close the socket since no connection delegate was found
//    //        }
//    //        NSLog("Got connection event: \(callbackType), \(socketTransport), \(clientSocket)");
//    //    } else if (callback
//}
