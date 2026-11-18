export interface ShippingQuoteRequest {
  regionCode: string;
  totalWeightGrams: number;
}

export interface ShippingQuote {
  provider: string;
  regionCode: string;
  amountMinor: string;
  currencyCode: "EGP";
  expiresAt: string;
}

export interface ShippingProviderAdapter {
  readonly provider: string;
  quote(request: ShippingQuoteRequest): Promise<ShippingQuote>;
}
