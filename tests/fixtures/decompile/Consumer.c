// Callsites are deliberately out of selector order.
bool consumeCold(YTColdConfig *config)
{
  return -[YTColdConfig zebraFlag](config, "zebraFlag");
}

bool consumeGlobal(YTGlobalConfig *config)
{
  return -[YTGlobalConfig alphaFlag](config, "alphaFlag");
}
