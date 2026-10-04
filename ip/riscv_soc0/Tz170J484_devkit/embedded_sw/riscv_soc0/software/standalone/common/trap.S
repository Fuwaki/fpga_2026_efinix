// This config is for RV32 Only !
.global  trap_entry
.align(2) 

#ifdef __riscv_flen
  #if __riscv_flen == 64 // This is for RV_DF extension (64bit)
    #define FSTORE    fsd
    #define FLOAD     fld
    #define FPR_SIZE   8   //Size of Floating Point Register (Byte)
    #define STACK_SIZE 240 //16-byte alligment
  #else // This is for RV_F extension (32bit)
    #define FSTORE    fsw
    #define FLOAD     flw
    #define FPR_SIZE   4  
    #define STACK_SIZE 160
  #endif
#endif

trap_entry:
#ifdef __riscv_flen
  addi sp, sp, -STACK_SIZE
#else
  addi sp, sp, -64
#endif
  sw x1,   0*4(sp)
  sw x5,   1*4(sp)
  sw x6,   2*4(sp)
  sw x7,   3*4(sp)
  sw x10,  4*4(sp)
  sw x11,  5*4(sp)
  sw x12,  6*4(sp)
  sw x13,  7*4(sp)
  sw x14,  8*4(sp)
  sw x15,  9*4(sp)
  sw x16, 10*4(sp)
  sw x17, 11*4(sp)
  sw x28, 12*4(sp)
  sw x29, 13*4(sp)
  sw x30, 14*4(sp)
  sw x31, 15*4(sp)

#ifdef __riscv_flen 
  FSTORE f0,  64 + 0*FPR_SIZE(sp) //64 is the offset for integer reg
  FSTORE f1,  64 + 1*FPR_SIZE(sp)
  FSTORE f2,  64 + 2*FPR_SIZE(sp)
  FSTORE f3,  64 + 3*FPR_SIZE(sp)
  FSTORE f4,  64 + 4*FPR_SIZE(sp)
  FSTORE f5,  64 + 5*FPR_SIZE(sp)
  FSTORE f6,  64 + 6*FPR_SIZE(sp)
  FSTORE f7,  64 + 7*FPR_SIZE(sp)
  FSTORE f10, 64 + 8*FPR_SIZE(sp)
  FSTORE f11, 64 + 9*FPR_SIZE(sp)
  FSTORE f12, 64 + 10*FPR_SIZE(sp)
  FSTORE f13, 64 + 11*FPR_SIZE(sp)
  FSTORE f14, 64 + 12*FPR_SIZE(sp)
  FSTORE f15, 64 + 13*FPR_SIZE(sp)
  FSTORE f16, 64 + 14*FPR_SIZE(sp)
  FSTORE f17, 64 + 15*FPR_SIZE(sp)
  FSTORE f28, 64 + 16*FPR_SIZE(sp)
  FSTORE f29, 64 + 17*FPR_SIZE(sp)
  FSTORE f30, 64 + 18*FPR_SIZE(sp)
  FSTORE f31, 64 + 19*FPR_SIZE(sp)
  csrr t0, fcsr
  sw t0, 64 + 20*FPR_SIZE(sp)
#endif
  call trap
#ifdef __riscv_flen
  lw t0, 64 + 20*FPR_SIZE(sp)
  csrw fcsr, t0
  FLOAD f0,  64 + 0*FPR_SIZE(sp)
  FLOAD f1,  64 + 1*FPR_SIZE(sp)
  FLOAD f2,  64 + 2*FPR_SIZE(sp)
  FLOAD f3,  64 + 3*FPR_SIZE(sp)
  FLOAD f4,  64 + 4*FPR_SIZE(sp)
  FLOAD f5,  64 + 5*FPR_SIZE(sp)
  FLOAD f6,  64 + 6*FPR_SIZE(sp)
  FLOAD f7,  64 + 7*FPR_SIZE(sp)
  FLOAD f10, 64 + 8*FPR_SIZE(sp)
  FLOAD f11, 64 + 9*FPR_SIZE(sp)
  FLOAD f12, 64 + 10*FPR_SIZE(sp)
  FLOAD f13, 64 + 11*FPR_SIZE(sp)
  FLOAD f14, 64 + 12*FPR_SIZE(sp)
  FLOAD f15, 64 + 13*FPR_SIZE(sp)
  FLOAD f16, 64 + 14*FPR_SIZE(sp)
  FLOAD f17, 64 + 15*FPR_SIZE(sp)
  FLOAD f28, 64 + 16*FPR_SIZE(sp)
  FLOAD f29, 64 + 17*FPR_SIZE(sp)
  FLOAD f30, 64 + 18*FPR_SIZE(sp)
  FLOAD f31, 64 + 19*FPR_SIZE(sp)
#endif
  lw x1 ,  0*4(sp)
  lw x5,   1*4(sp)
  lw x6,   2*4(sp)
  lw x7,   3*4(sp)
  lw x10,  4*4(sp)
  lw x11,  5*4(sp)
  lw x12,  6*4(sp)
  lw x13,  7*4(sp)
  lw x14,  8*4(sp)
  lw x15,  9*4(sp)
  lw x16, 10*4(sp)
  lw x17, 11*4(sp)
  lw x28, 12*4(sp)
  lw x29, 13*4(sp)
  lw x30, 14*4(sp)
  lw x31, 15*4(sp)
#ifdef __riscv_flen
  addi sp, sp, STACK_SIZE
#else
  addi sp, sp, 64
#endif
  mret