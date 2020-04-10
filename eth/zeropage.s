.global read_blkptr, write_blkptr, bank_save

.segment "ZPETH" : zeropage

read_blkptr:
	.res 2
write_blkptr:
	.res 2
bank_save:
	.res 1
