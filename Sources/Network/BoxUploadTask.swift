//
//  BoxUploadTask.swift
//  BoxSDK-iOS
//
//  Created by Sujay Garlanka on 4/24/20.
//  Copyright © 2020 box. All rights reserved.
//

import Foundation

/// A Box network task returned for a upload
public class BoxUploadTask: BoxNetworkTask {
    var nestedTask: BoxNetworkTask?

    public func receiveTask(_ networkTask: BoxNetworkTask) {
        if cancelled {
            networkTask.cancel()
        }
        else {
            nestedTask = networkTask
        }
    }

    /// Method to cancel a network task
    public override func cancel() {
        task?.cancel()
        nestedTask?.cancel()
        cancelled = true
    }
}
