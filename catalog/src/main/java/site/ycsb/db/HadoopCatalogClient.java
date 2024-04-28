package site.ycsb.db;


import org.apache.hadoop.conf.Configuration;
import org.apache.iceberg.hadoop.HadoopCatalog;
import site.ycsb.DBException;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.util.Map;

public class HadoopCatalogClient extends CatalogClient {



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
