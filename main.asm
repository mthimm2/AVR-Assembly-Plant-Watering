;
; Garden_v6.asm
;
; Created: 07/14/2020 12:09 P.M.
; Author : Max Thimmig

/* 

 Pinout:

	D5: PWM Output to H-Bridge pin 2
	D8: Status LED Output
	A0: Soil Moisture Sensor Input

*/

/*

 GP Register Use Table:

	r15: SREG preservation in ADC interrupt
	r16: Register configuration in setup
	r17: DDRD enable/disable for pump
	r18: Moisture threshold constant to compare against for pump control logic
	r19: LED state
	r20: Unused
	r21: XOR LED toggle constant register
	r22: Unused
	r23: Holds ADCH from the ADC interrupt
	r24: Holds "recently watered" flag
	r25: Used for LED blink delay
	r26: Used for LED blink delay
	r27: Used for LED blink delay

*/

/*
v6 Change Log:

	Complete redux to reflect updated PCB layout requirements
	Status LED blink changed from interrupt to manual delay.
	PWM changed to Timer/Counter 0 to assist in trace routing.
	Timer1 Interrupt removed
*/

; In order to let the assembler know what subroutine to run, we need to use the ".org [Interrupt Vector]" directive.
; The following line of code will let the ATMEGA know to be on the lookout for when the interrupt flag is set within the register.

;RESET vector
.org 0x0000
	rjmp setup

; ADC_vect
.org 0x002A
	rjmp ADC_vect

setup:

	; Disable global interrupts
	cli

	; DDRB = 0x01 for Status LED
	ldi r16, 0x01
	out DDRB, r16

	; DDRD = 0x20 for PWM signal
	ldi r16, 0x20
	out DDRD, r16

	; TCNT0 Configuration
	; Phase-Correct PWM, Prescaler of 8, Frequency of 25Khz
	ldi r16, 0x21
	out TCCR0A, r16
	ldi r16, 0x0A
	out TCCR0B, r16

	; OCR0A and OCR0B config for duty cycle. Should come out to ~4V.
	ldi r16, 40
	out OCR0A, r16
	ldi r16, 34
	out OCR0B, r16

	; ADC Configuration, free-running mode
	
	; ADC in auto-process data mode, Prescaler of 128.
	; ADCSRA = 0xEF;
	ldi r16, 0xEF
	sts ADCSRA, r16
	
	; ADCSRB = 0x00;
	ldi r16, 0x00
	sts ADCSRB, r16

	; ADLAR = 1 so that we can just look at ADCH, essentially.
	; Read sensor input from pin A0
	ldi r16,  0x60
	sts ADMUX, r16

	; The Watchdog timer has to be configured in 2 steps.
	; The reason for this, is that one bit in the WDTCSR register must be set, before a different bit can be set, allowing the configuration to be completed.
	; First WDTCSR write to enable the WDT with a timeout period of 4 seconds.
	ldi r16, 0x18
	sts WDTCSR, r16

	; Finish the WDT setup by setting the bits that control the 4 second timeout period.
	ldi r16, 0x38
	sts WDTCSR, r16

	; r19 will hold the LED state for register toggling. r21 will be used to eor against r19
	ldi r19, 0x00
	ldi r21, 0x01

	; r18 can hold the const SOIL_MOISTURE_THRESHOLD
	; We're no longer doing a conversion between the ADC result and a 0-100 scale.
	; Recall that from the ADC, a result of ~600 = dry and a result < ~480 = sufficiently watered
	; 480 >> 2 = 120 = 0x78, hence the value loaded into r18
	ldi r18, 0x78

	/*
		When the plant is watered, I want the plant to be watered "sufficiently", i.e: brought down to a soil moisture reading that does not indicate waterlogging
		The system should water the plant down to the threshold value, then wait until the soil dries out a bit before watering again.
		Therefore, I'll let the ADCH value back off by 20 before ever proceeding to water again.
		r24 is going to hold either a 1 or a 0 to indicate whether the plant was recently watered or not.
		If the plant wasn't recently watered, it will be watered down to the setpoint, then the flag will be set.
		Watering will not take place again until the value in ADCH is 20 (decimal) higher than the setpoint value.
		Recently watered = 1, Not recently watered = 0
	*/
	ldi r24, 0

	// Finally, we'll turn off TWI, SPI, TCNT1 and 2, and USART because we're not actively using them in this circuit.
	ldi r16, 0xCE
	sts PRR, r16

	; Re-enable global interrupts
	sei

	; Proceed to the loop
	rjmp loop
	
loop:

	; Reset the Watchdog Timer, so that the program doesn't time out.
	WDR

	; Set up registers for the 1s delay between LED blinks, toggle the LED state, perform the delay, then output the LED state.
	ldi r25, 41
	ldi r26, 150
	ldi r27, 126
	eor r19, r21
	call LED_blink_delay
	out PORTB, r19

	; Check to see if the "recently watered flag" is set
	; If it isn't, then we can just water the plants as normal
	cpi r24, 1
	brlo watering_decision

	; If we make it here, the garden was recently watered.
	; In this case, we need to see if we've let the soil dry out a bit
	rjmp ten_higher_than_threshold
	;rjmp loop

watering_decision:

	; See if the ADC result is lower than the threshold.
	; If it is, the watering is sufficient
	cp r23, r18
	brlo pump_disable

	; Otherwise, we can enable the pump and start watering.
	rjmp pump_enable

ten_higher_than_threshold:

	; Simply check to see if the value in r23 is the same or greater than 0x8C, which is 20 (in decimal) higher than the threshold value
	; If ADCH is finally 20 above the threshold, we can reset the "recently watered" flag.
	cpi r23, 0x8C
	brsh reset_recently_watered_flag

	; Otherwise, head back to the loop
	rjmp loop

pump_disable:

	; Put the kabosh on the PWM pin for the time being.
	ldi r17, 0x00
	out DDRD, r17

	; If we disabled the pump, then the watering is/was sufficient.
	; Therefore, we can set the recently watered flag.
	ldi r24, 1

	; Jump back to the loop for infinite looping
	rjmp loop

pump_enable:

	; Reinstate the PWM pin as output
	ldi r17, 0x20
	out DDRD, r17

	; Jump back to the loop
	rjmp loop

reset_recently_watered_flag:

	; Reset the flag to 0 then head back to the main loop
	ldi r24, 0
	rjmp loop

LED_blink_delay:

	; 1 second delay, done in the braindead way.
	dec  r27
    brne LED_blink_delay
    dec  r26
    brne LED_blink_delay
    dec  r25
    brne LED_blink_delay
	ret

ADC_vect:

	; Preserve the state of SREG
	in r15, SREG

	; Take the high byte of the ADC and load it into r23
	lds r23, ADCH

	; Restore SREG
	out SREG, r15

	; ISR complete
	reti