package site.ycsb.db;


import org.apache.commons.lang3.RandomStringUtils;
import org.apache.hadoop.conf.Configuration;
import org.apache.iceberg.hadoop.HadoopCatalog;
import site.ycsb.DBException;

import java.io.File;
import java.io.FileInputStream;

public class HadoopCatalogClient extends CatalogClient<HadoopCatalog> {

  protected static final String warehouse = "gs://benchmarking-ycsb/" + RandomStringUtils.randomAlphanumeric(8);
  protected static final String gs_location = warehouse + "/catalog";

  final File credentials() {
    // https://cloud.google.com/docs/authentication/provide-credentials-adc#local-dev
    String location = System.getenv("GOOGLE_APPLICATION_CREDENTIALS");
    if (null == location) {
      location = getProperties().getProperty("gcp.creds");
    }
    if (null == location) {
      throw new IllegalArgumentException("Missing credential location");
    }
    return new File(location);
  }

  @Override
  public void init() throws DBException {

    String creds;
    try (FileInputStream credentials = new FileInputStream(credentials())) {
      creds = credentials.toString();
    } catch (Exception e){
      throw new DBException("Failed to load credentials");
    }

    Configuration conf = new Configuration();
    conf.set("fs.AbstractFileSystem.gs.impl", "com.google.cloud.hadoop.fs.gcs.GoogleHadoopFS");
    conf.set("google.cloud.auth.type", creds.toString());
    catalog = new HadoopCatalog(conf, gs_location);
  }
}
