import Foundation
import Virtualization

final class Delegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fputs("zfsbox-vz: vm stopped with error: \(error)\n", stderr)
        exit(1)
    }
}

struct Options {
    var kernel = ""
    var initrd = ""
    var rootfs = ""
    var seed = ""
    var stateShare = ""
    var hostShare = ""
    var serialLog = ""
    var attachments: [String] = []
}

func parseArgs() -> Options {
    var options = Options()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()

    while let arg = iterator.next() {
        switch arg {
        case "--kernel":
            options.kernel = iterator.next() ?? ""
        case "--initrd":
            options.initrd = iterator.next() ?? ""
        case "--rootfs":
            options.rootfs = iterator.next() ?? ""
        case "--seed":
            options.seed = iterator.next() ?? ""
        case "--state-share":
            options.stateShare = iterator.next() ?? ""
        case "--host-share":
            options.hostShare = iterator.next() ?? ""
        case "--serial-log":
            options.serialLog = iterator.next() ?? ""
        case "--attach":
            if let value = iterator.next() {
                options.attachments.append(value)
            }
        default:
            fputs("unknown arg: \(arg)\n", stderr)
            exit(2)
        }
    }

    return options
}

func makeAttachment(for path: String) throws -> VZStorageDeviceAttachment {
    if path.hasPrefix("/dev/") {
        let fileHandle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        return try VZDiskBlockDeviceStorageDeviceAttachment(fileHandle: fileHandle, readOnly: false, synchronizationMode: .full)
    }

    return try VZDiskImageStorageDeviceAttachment(
        url: URL(fileURLWithPath: path),
        readOnly: false,
        cachingMode: .automatic,
        synchronizationMode: .fsync
    )
}

func main() throws {
    let options = parseArgs()
    let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: options.kernel))
    bootLoader.initialRamdiskURL = URL(fileURLWithPath: options.initrd)
    bootLoader.commandLine = "console=hvc0 root=/dev/vda1 rw"

    let rootAttachment = try VZDiskImageStorageDeviceAttachment(
        url: URL(fileURLWithPath: options.rootfs),
        readOnly: false,
        cachingMode: .automatic,
        synchronizationMode: .fsync
    )
    let rootBlock = VZVirtioBlockDeviceConfiguration(attachment: rootAttachment)

    var storageDevices: [VZStorageDeviceConfiguration] = [rootBlock]
    if !options.seed.isEmpty {
        let seedAttachment = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: options.seed), readOnly: true)
        let seedBlock = VZVirtioBlockDeviceConfiguration(attachment: seedAttachment)
        storageDevices.append(seedBlock)
    }
    for (index, path) in options.attachments.enumerated() {
        let attachment = try makeAttachment(for: path)
        let block = VZVirtioBlockDeviceConfiguration(attachment: attachment)
        block.blockDeviceIdentifier = "zfsbox-\(index)"
        storageDevices.append(block)
    }

    let config = VZVirtualMachineConfiguration()
    config.platform = VZGenericPlatformConfiguration()
    config.bootLoader = bootLoader
    config.cpuCount = 2
    config.memorySize = 2 * 1024 * 1024 * 1024
    config.storageDevices = storageDevices
    let networkConfig = VZVirtioNetworkDeviceConfiguration()
    networkConfig.attachment = VZNATNetworkDeviceAttachment()
    networkConfig.macAddress = VZMACAddress(string: "02:00:00:00:00:01")!
    config.networkDevices = [networkConfig]
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    let serialRead = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
    let serialWriteURL = URL(fileURLWithPath: options.serialLog)
    FileManager.default.createFile(atPath: serialWriteURL.path, contents: nil)
    let serialWrite = try FileHandle(forWritingTo: serialWriteURL)
    try serialWrite.seekToEnd()
    let serialAttachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: serialRead,
        fileHandleForWriting: serialWrite
    )
    let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
    serialConfig.attachment = serialAttachment
    config.serialPorts = [serialConfig]

    try config.validate()

    let delegate = Delegate()
    let vm = VZVirtualMachine(configuration: config)
    vm.delegate = delegate

    withExtendedLifetime((delegate, serialRead, serialWrite)) {
        vm.start { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                fputs("zfsbox-vz: failed to start vm: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}

do {
    try main()
} catch {
    fputs("zfsbox-vz: \(error)\n", stderr)
    exit(1)
}
