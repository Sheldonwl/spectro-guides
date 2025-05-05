# Creating UKI (Unified Kernel Image) Images

## What is a UKI Image?

A UKI (Unified Kernel Image) is a secure boot-enabled image that combines the kernel, initramfs, and other boot components into a single, signed EFI binary. This approach enhances system security by ensuring the integrity of the boot process through cryptographic verification.

## Using UKI Images Without Secure Boot

While UKI images are designed with Secure Boot in mind, they can be used without enabling Secure Boot. Here's what you need to know:

1. **Flexibility in Deployment**
   - UKI images can be used with Secure Boot disabled
   - The system will boot normally without boot verification
   - You can enable Secure Boot later if needed

2. **Benefits Without Secure Boot**
   - Simplified boot configuration
   - Easier updates and management
   - Better organization of boot components
   - Unified format for kernel and initramfs

3. **Considerations**
   - You won't get the security benefits of boot verification
   - The image will function like a regular boot image
   - You can still use all other UKI features

## Creating a UKI Image

### Prerequisites

1. A system with UEFI firmware
2. Secure Boot support in the firmware
3. Required tools and certificates

### Configuration Steps

1. Set up your `.arg` file with the following parameters:
```yaml
IS_UKI=true
UKI_BRING_YOUR_OWN_KEYS=false  # Set to true if using your own keys
INCLUDE_MS_SECUREBOOT_KEYS=true  # Include Microsoft's Secure Boot certificates
AUTO_ENROLL_SECUREBOOT_KEYS=false  # Auto-enroll keys during boot
```

2. **Required: Generate Secure Boot Keys First**
   - Even if you don't plan to use Secure Boot, you must generate the keys first
   - Run the following command to create the secure-boot directory structure and generate keys:
   ```bash
   ./earthly.sh +uki-genkey --MY_ORG="Your Organization" --EXPIRATION_IN_DAYS=5475
   ```
   - This will create the required directory structure:
   ```
   secure-boot/
   ├── enrollment/
   ├── exported-keys/
   │   ├── db
   │   ├── KEK
   │   └── dbx
   ├── private-keys/
   │   ├── db.key
   │   ├── KEK.key
   │   ├── PK.key
   │   └── tpm2-pcr-private.pem
   └── public-keys/
       ├── db.pem
       ├── KEK.pem
       └── PK.pem
   ```

3. Build the UKI image:
```bash
./earthly.sh +build-all-images
```

## Pros of Using UKI Images

1. **Enhanced Security**
   - Cryptographic verification of boot components
   - Protection against bootkit and rootkit attacks
   - Secure boot chain from firmware to OS

2. **Simplified Boot Process**
   - Single, unified boot image
   - Reduced complexity in boot configuration
   - Easier to manage and update

3. **Compliance**
   - Meets security requirements for regulated environments
   - Supports FIPS compliance when combined with FIPS-enabled components
   - Aligns with modern security best practices

4. **Trusted Computing**
   - Integration with TPM (Trusted Platform Module)
   - Measured boot capabilities
   - Hardware-based security features

## Cons of Using UKI Images

1. **Complexity in Setup**
   - Requires careful key management
   - More complex initial configuration
   - Need for proper certificate handling

2. **Compatibility Issues**
   - May not work with all hardware
   - Requires UEFI firmware support
   - Some older systems may not be compatible

3. **Recovery Challenges**
   - More difficult to recover from boot failures
   - Requires proper key backup and management
   - Potential for system lockout if keys are lost

4. **Performance Impact**
   - Slightly longer boot times due to verification
   - Additional overhead from security checks
   - Resource usage for cryptographic operations

## Best Practices

1. **Key Management**
   - Securely store and backup your keys
   - Use appropriate key rotation policies
   - Implement proper access controls for keys

2. **Testing**
   - Test UKI images in your specific environment
   - Verify compatibility with your hardware
   - Test recovery procedures

3. **Documentation**
   - Maintain clear documentation of your setup
   - Document key management procedures
   - Keep track of certificate expiration dates

4. **Monitoring**
   - Monitor boot process for any issues
   - Track security events
   - Implement proper logging

## Conclusion

UKI images provide a robust security solution for modern systems, particularly in environments where security is paramount. While they require more initial setup and management, the security benefits often outweigh the additional complexity. Careful planning and proper implementation are essential for successful deployment. 