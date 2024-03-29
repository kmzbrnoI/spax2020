;      SPAX2020
; ---------------------
; Spax s lépe řešenou detekcí zkratu
;
; author: Michal Petrilak, Jan Horacek
; assembler: gpasm
;
; For simulation, marked lines in ‹init› must be commented out
;
; Toff = 30 ms, 2.5 W on stabilizer when short-circuit
        list p=12f629
        #include <p12f629.inc>
        errorlevel -305,-302
        __CONFIG  _BODEN_ON & _CP_OFF & _WDT_OFF & _MCLRE_OFF & _PWRTE_OFF & _INTRC_OSC_NOCLKOUT & 31FF

;GP0    enable booster
;GP1    sense (CIN-)
;GP2    DCC_in2
;GP3    DCC_in1
;GP4    led green
;GP5    led red

; BITY/PINY
#define     DCC_in1     GPIO,3
#define     DCC_in2     GPIO,2
#define     overC       CMCON,COUT

#define     led_green   GP_ram,4
#define     led_red     GP_ram,5
#define     drv_en      GP_ram,0

; Main timer 1
CTIMET1     equ     0x100 - d'20'       ; master timer T = 5.12 ms (4 MHz / 4 / 1 / 256 / 20)
CTIMET1L    equ     0x100 - d'100'      ; |
DCC_CHCK    equ     d'10'
DCC_post    equ     d'3'                ; timer postscaler

; Timer 0 for reading short-circuit detection
CTIMET0     equ     0x100 - d'125'      ; timer T = 500 us

short_t1    equ     d'04'               ; short-circuit react time (first & permanent) 04 = 20 ms
short_t2    equ     d'01'               ; short-circuit react time (repeated) 01 =  5 ms
set_res_t0  equ     d'020'              ;   (100 ms) delays between restore attempts
set_res_t1  equ     d'040'              ; | (200 ms)
set_res_t2  equ     d'080'              ; | (400 ms)
set_res_t3  equ     d'120'              ; | (600 ms))

GP_TRIS     equ     b'00001110'         ; only analog inputs: GP0, GP1
GP_INI      equ     b'00000000'         ; all zero
OPTION_INI  equ     b'10000001'         ; Option reg: no pull-up, falling GP2, TMR0 prescaler 4
CMCON_INI   equ     b'00000100'         ; comparator GP1 input,use Vref, no output
INTCON_INI  equ     b'10001000'         ; interrupt enable from GPchange, global enable
VRCON_INI   equ     b'10001000'         ; Vref enabled, V=2.5V @ Vcc=5V
IOC_INI     equ     b'00001100'         ; interrupt on change GPIO 2,3
T1CON_INI   equ     b'00000001'         ; T1 internal clock, prescaler 1, LP off, gate allways on, running

#define     BANK0       bcf STATUS,RP0
#define     BANK1       bsf STATUS,RP0

#define     IRQ_IOC_ENA bsf INTCON, GPIE
#define     IRQ_IOC_DIS bcf INTCON, GPIE
#define     IRQ_IOC_CLR bcf INTCON, GPIF

cblock 0x20
            ; reserver for DCC cedocer
endc

cblock 0x30
            tmpw
            tmps
            GP_ram
            flags
            flags_DCC
            state
            DCC_cnt
            LED_cnt
            short_cnt
            DCCtmr_post
            restore_state     ; output restoring state (how long to wait)
            restore_cnt       ; output restoring counter (4xT1)
            overload_debouncer
            over_cnt
endc

#define     fDCC1_hi    flags_DCC,0 ; DCC test internal flags
#define     fDCC1_lo    flags_DCC,1
#define     fDCC2_hi    flags_DCC,2
#define     fDCC2_lo    flags_DCC,3
#define     fTimer      flags,0
#define     fblik       flags,1
#define     fblikmask   b'00000010'
#define     fDCCok      flags,2     ; delayed flag DCC
#define     fDCCtstok   flags,3     ; fast test DCC
#define     foverR      flags,4     ; return value of overload
#define     fover       flags,5     ; long-time state of overload (poll this value to ask)

#define     s_drv_en     state,0; output state
#define     s_overcur    state,1; overcurrent detected


; ****************************
; **         START          **
; ****************************

            org 0                   ; entry point
            movlw   GP_INI          ; reset GPIO
            movwf   GPIO
            movwf   GP_ram
            goto    init            ; goto init

            org 4
irq:        movwf   tmpw            ; irq
            swapf   STATUS, w       ; save state
            movwf   tmps

            btfsc   INTCON,GPIF
            goto    irq_dcc
            nop                     ; unknown interrupt
            goto    irq_end

irq_dcc:    IRQ_IOC_CLR             ; test DCC pins and set flags
            btfsc   DCC_in1
            bsf     fDCC1_hi
            btfss   DCC_in1
            bsf     fDCC1_lo
            btfsc   DCC_in2
            bsf     fDCC2_hi
            btfss   DCC_in2
            bsf     fDCC2_lo

irq_end:    swapf   tmps,W          ; restore state
            movwf   STATUS
            swapf   tmpw,f
            swapf   tmpw,w
            retfie                  ; irq end

irq_notused:
            goto    irq_end

; ****************************
; **       Tabulky          **
; ****************************

ref_tab:    ANDLW   0x03
            ADDWF   PCL, F
            RETLW   set_res_t0
            RETLW   set_res_t1
            RETLW   set_res_t2
            RETLW   set_res_t3

jump_state: MOVF    state,w
            ANDLW   0x03
            ADDWF   PCL, F
            GOTO    state_0          ; invalid
            GOTO    state_1          ; run
            GOTO    state_2          ; poweroff
            GOTO    state_3          ; recovery

;state diagram:
;    power on = state 0 -> state 1
;    short    = state 1 -> state 2
;               state 3 -> state 2
;    wait     = state 2 -> state 3
;    no short = state 3 -> state 1


; ****************************
; **         INIT           **
; ****************************

init:                               ; init
            BANK1
            movlw   GP_TRIS
            movwf   TRISIO
            call    0x3FF          ; get OSCCAL value; comment out this for simulation
            movwf   OSCCAL         ; comment out this for simulation
;            nop
;            nop
            movlw   IOC_INI
            movwf   IOC
            movlw   VRCON_INI
            movwf   VRCON
            movlw   OPTION_INI
            movwf   OPTION_REG
            BANK0
            movlw   CMCON_INI
            movwf   CMCON
            movlw   0x5f            ; clear RAM (0x20 - 0x5f)
            movwf   FSR
clrRAM:     decf    FSR,w
            movwf   FSR
            clrf    INDF

            sublw   0x20
            btfss   STATUS, C
            goto    clrRAM

            movlw   T1CON_INI       ; enable timer 1
            movwf   T1CON           ; |
            movlw   0xff            ; |
            movwf   TMR1H           ; |
            movlw   DCC_post        ; |
            movwf   DCCtmr_post     ; |
            IRQ_IOC_ENA

            movlw   0xff            ; enable timer 0
            movwf   TMR0            ; |

            movlw   INTCON_INI      ; enable interrupts
            movwf   INTCON
init_end:

; ****************************
; **       Main Loop        **
; ****************************

main:
            movfw   GP_ram          ; copy GP_ram to outputs
            movwf   GPIO            ; |
            movfw   GPIO            ; read GPIO (for IOC work)

            call    DCCtstfast
            call    handleLed

ma_0:
            ; TIMER 0
            BTFSS   INTCON,T0IF     ; T0 overflow?
            GOTO    ma_1            ; no, go to ma_1

T0:         BCF     INTCON,T0IF     ; T0 overflow, clear overflow flag
            MOVLW   CTIMET0         ; initialize time T0
            ADDWF   TMR0, F         ; |

            CALL    overload_detect ; is overload?
            BTFSC   foverR          ; |
            GOTO    overload        ; yes
no_overload:INCF    over_cnt, F     ; no: if (over_cnt > 0) over_cnt--;
            DECFSZ  over_cnt, F     ; |
            DECF    over_cnt, F     ; |
            GOTO    calc_fover
overload:   BTFSS   over_cnt, 3     ; overload: if (over_cnt < 8) over_cnt++;
            INCF    over_cnt, F     ; |
            GOTO    calc_fover      ; |

calc_fover:
            MOVLW   0x0C            ; fover = (over_cnt >= 4);
            ANDWF   over_cnt, W     ; |
            MOVWF   tmpw            ; |
            INCF    tmpw, F         ; |
            DECFSZ  tmpw, F         ; |
            GOTO    fover_true      ; (over_cnt >= 4) -> set overload on
fover_not_true:                     ; clear fover only in (over_cnt < 2) to add hysteresis
            MOVLW   0x0E
            ANDWF   over_cnt, W
            MOVWF   tmpw
            INCF    tmpw, F
            DECFSZ  tmpw, F         ; first decrement
            GOTO    ma_1            ; > 0 -> original number >= 2 -> exit
            BCF     fover           ; 0 -> clear fover
            GOTO    ma_1
fover_true: BSF     fover

ma_1:
            ; TIMER 1
            BTFSS   PIR1,TMR1IF     ; T1 overflow?
            GOTO    main            ; no, loop
; ** T1 **
T1:         BCF     PIR1,TMR1IF     ; yes, clear overflow flag
            MOVLW   CTIMET1         ; initialize time T1
            MOVWF   TMR1H           ; T1 = 4.9152 ms
            MOVLW   CTIMET1L        ; |
            ADDWF   TMR1L, F        ; |

            decfsz  DCCtmr_post     ; postscaler for DCC testing
            goto    nodcctst
            movlw   DCC_post
            movwf   DCCtmr_post
            call    DCCtst          ; solve DCC detection

nodcctst:
            GOTO    jump_state      ; state machine - begin

            ; invalid state
state_0:    MOVLW   1               ; goto state 1
            MOVWF   state
            movlw   1
            movwf   short_cnt
            GOTO    T1_end

            ; running, all ok
state_1:    BTFSC   fover           ; if (overcurrent)
            GOTO    calc_OC         ; yes, solve what to do
            MOVF    short_cnt, W    ; no, test if short_cnt is in normal state (short_cnt == short_t1)
            SUBLW   short_t1        ; |
            BTFSS   STATUS,Z        ; |
            INCF    short_cnt, F    ; no, increment by 1
            GOTO    T1_end
calc_OC:
            DECFSZ  short_cnt, f    ; measure overcurrent time, is it enought?
            GOTO    T1_end          ; no, do nothing now
            MOVLW   0x01            ; yes, move to next state (poweroff)
            ADDWF   state,f
            MOVLW   0x00            ; set first recover interval
            MOVWF   restore_state   ; |
            CALL    ref_tab         ; |
            MOVWF   restore_cnt     ; |
            GOTO    T1_end

            ; short cirtuit, track off
state_2:    DECFSZ  restore_cnt,f   ; measure recovery wait time
            GOTO    T1_end          ; if (restore_cnt > 0) then wait

            MOVF    restore_state,w ; |
            SUBLW   d'02'           ; if (restore_state < 3)
            MOVLW   short_t1        ; |
            BTFSC   STATUS,C        ; yes, set t1
            MOVLW   short_t2        ; no, set t2
            MOVWF   short_cnt       ; |
            MOVLW   0x01            ; move to next state (recovery)
            ADDWF   state,f
            GOTO    T1_end

            ; short circuit, track on, recovery
state_3:    BTFSC   fover           ; if (overcurrent)
            GOTO    calc_OC2        ; yes, solve what to do
            DECFSZ  short_cnt, f    ; no, if (short_cnt == 0)
            GOTO    T1_end          ; no, do nothing
            MOVLW   0x00            ; yes, go to state 1 (run)
            MOVWF   restore_state   ; |
            MOVLW   0x01            ; |
            MOVWF   state           ; |
            GOTO    T1_end

calc_OC2:   DECFSZ  short_cnt, f    ; enough time in state 3 and overcurrent ?
            GOTO    T1_end          ; no, do nothing
            MOVLW   0x02            ; overcurrent detected, go to state 2
            MOVWF   state           ; |
            MOVF    restore_state,w ; if (restore_state < 3)
            SUBLW   d'02'           ; |
            BTFSC   STATUS,C        ; |
            INCF    restore_state,f ; yes, restore_state++
            MOVFW   restore_state   ; |
            CALL    ref_tab         ; get restore_cnt
            MOVWF   restore_cnt     ; |

            GOTO    T1_end



T1_end:
            BCF     drv_en          ; drv_en (output) = !(s_drv_en & fDCCok)
            BTFSS   s_drv_en        ; |
            GOTO    main            ; |
            BTFSS   fDCCok          ; |
            GOTO    main            ; |
            BSF     drv_en          ; |
            GOTO    main

; ****************************
; **       Functions        **
; ****************************

DCCtstfast: movfw   flags_DCC       ; fDCCtstok = fDCC1_hi AND fDCC1_lo AND fDCC2_hi AND fDCC2_lo
            xorlw   0x0f            ; all 4 flags must be set, then set fDCCtstok
            btfss   STATUS, Z
            bcf     fDCCtstok
            btfsc   STATUS, Z
            bsf     fDCCtstok
            btfsc   fDCCtstok       ; if fDCCtstok then no more testing
            IRQ_IOC_DIS
            return

; ****************************

DCCtst:
            IRQ_IOC_CLR
            IRQ_IOC_ENA
            clrf    flags_DCC       ; DCC test begin

                                    ; delay DCCok flag
            btfss   fDCCtstok
            goto    DCCnok
            btfsc   fDCCok          ; test DCCok flag
            return
            incf    DCC_cnt, w      ; inc OK counter
            movwf   DCC_cnt
            sublw   DCC_CHCK        ; if (DCC_cnt > DCC_CHCK) then
            btfsc   STATUS, C
            return
            bsf     fDCCok          ; set DCCok flag
            return
DCCnok:
            bcf     fDCCok          ; reset DCCok flag
            clrf    DCC_cnt         ; clear DCC_cnt
            return

; ****************************

handleLed:
            btfsc   s_drv_en        ; copy s_drv_en to led green
            bsf     led_green
            btfss   s_drv_en
            bcf     led_green

            btfsc   drv_en          ; copy enable output to led red
            bcf     led_red
            btfss   drv_en
            bsf     led_red

            return

; ****************************

overload_detect:
            ; Overload pin short-time debouncing
            ; Debouncing always takes 16 us, measuring each 2 us
            ; Overload is reported when > 2 times overload is detected
            ; smallest interval between DCC change = 58 us (= capacitor loading = short overload; should be fine)

            MOVLW   0x02
            MOVWF   overload_debouncer

            BTFSC   overC           ; driver overload (int. comp.) ?
            DECF    overload_debouncer
            BTFSC   overC
            DECF    overload_debouncer
            BTFSC   overC
            DECF    overload_debouncer
            BTFSC   overC
            DECF    overload_debouncer
            BTFSC   overC
            DECF    overload_debouncer
            BTFSC   overC
            DECF    overload_debouncer
            BTFSC   overC
            DECF    overload_debouncer
            BTFSC   overC
            DECF    overload_debouncer

            BTFSC   overload_debouncer, 7 ; highest bit = 1 -> shortcut for >=2 measurements
            GOTO    is_overload
            BCF     foverR
            return
is_overload:
            BSF     foverR
            return


; ****************************

            END
