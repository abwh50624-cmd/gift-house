package com.bayt.elhadaya.ui.admin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AdminCatalogScreenTest {
    @Test
    fun parsePriceMinorConvertsEgpToExactMinorUnits() {
        assertEquals(12_500L, parsePriceMinor("125"))
        assertEquals(12_550L, parsePriceMinor("125.5"))
        assertEquals(12_555L, parsePriceMinor("125.55"))
    }

    @Test
    fun parsePriceMinorRejectsInvalidPrecisionNonPositiveAndOverflow() {
        assertNull(parsePriceMinor(""))
        assertNull(parsePriceMinor("0"))
        assertNull(parsePriceMinor("-1.00"))
        assertNull(parsePriceMinor("1.001"))
        assertNull(parsePriceMinor("999999999999999999999999"))
    }
}
