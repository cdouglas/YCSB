package site.ycsb.db;

import org.apache.iceberg.azure.adlsv2.LocationResolver;

public class HackOnAHack implements LocationResolver {
  public final String account;
  public final String container;
  HackOnAHack(String account, String container) {
    this.account = account;
    this.container = container;
  }
  @Override
  public String endpoint() {
    throw new UnsupportedOperationException();
  }

  @Override
  public com.azure.storage.file.datalake.DataLakeFileClient fileClient(String path) {
    throw new UnsupportedOperationException();
  }

  @Override
  public com.azure.storage.file.datalake.DataLakeServiceClient serviceClient() {
    throw new UnsupportedOperationException();
  }

  @Override
  public String account() {
    return account;
  }

  @Override
  public String container() {
    return container;
  }
}
