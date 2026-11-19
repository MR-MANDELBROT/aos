# Apache MINA SSHD loads parts of itself (security registrars, EdDSA) by name.
-keep class org.apache.sshd.** { *; }
-keep class net.i2p.crypto.eddsa.** { *; }
-dontwarn org.apache.sshd.**
-dontwarn org.slf4j.**
-dontwarn javax.management.**
-dontwarn org.bouncycastle.**
-dontwarn org.apache.tomcat.**
-dontwarn sun.security.**
